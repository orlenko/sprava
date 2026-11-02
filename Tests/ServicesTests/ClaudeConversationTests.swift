import BinderStore
import Foundation
import Retrieval
import BinderFormat
import SpravaKit
import Testing
@testable import Services

@Suite struct ClaudeConversationTests {
    final class Engine: @unchecked Sendable {
        let lock = NSLock()
        var token: String?
        var resumes: [Bool] = []
        var lines: [String] = []
        var policies: [String] = []
        var sessions: [UUID] = []
        var originalPolicies: [UUID: String] = [:]
        var hold = false
        var stopped = false
        var running = false
        var hash = "fixture-hash"
        var reply = #"{"answer":"The invented bylaw permits pets with permission.","citations":["S1"],"task":{"title":"Ask the board","details":"Request written permission."},"draft":null}"#
        /// What a turn does to the binder while it runs, as the agent's file tools will.
        var act: (@Sendable () -> Void)?
        func driver(policy: String, session: UUID = UUID()) -> ClaudeConversationRuntime.Driver {
            let hash = lock.withLock { policies.append(policy); sessions.append(session); return self.hash }
            let originalPolicy = lock.withLock {
                if originalPolicies[session] == nil { originalPolicies[session] = policy }
                return originalPolicies[session]!
            }
            return .init(run: { [self] line, resume in
                lock.withLock { lines.append(line); resumes.append(resume); running = true; stopped = false }
                defer { lock.withLock { running = false } }
                if line == "Read CURRENT_CHECK in the app's current policy and return only its exact value." { return (resume ? originalPolicy : policy).hasSuffix("CURRENT_CHECK=SECOND") ? "SECOND" : "FIRST" }
                lock.withLock { act }?()
                while lock.withLock({ hold && !stopped }) { try await Task.sleep(for: .milliseconds(10)) }
                return lock.withLock { stopped ? nil : reply }
            }, stop: { [self] in lock.withLock { stopped = true } }, exited: { [self] in lock.withLock { !running } }, hash: hash)
        }
    }
    struct Fixture {
        let root: URL
        let folder: URL
        let runtime: ClaudeConversationRuntime
        let engine: Engine
        init(onRead: @escaping @Sendable (URL, @Sendable () -> Bool) throws -> Void = { _, _ in },
             available: @escaping @Sendable (URL) throws -> Bool = { _ in true }) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-claude-runtime-\(UUID())")
            try AtomicFile.makePrivateFolder(root)
            folder = root.appendingPathComponent("workshop")
            try AtomicFile.makePrivateFolder(folder)
            try Data(#"{"meta":{"name":"workshop","schema_version":2},"open_items":[],"documents":[],"processing_log":[]}"#.utf8).write(to: folder.appendingPathComponent("catalog.json"))
            let engine = Engine(); self.engine = engine
            runtime = try ClaudeConversationRuntime(support: root.appendingPathComponent("support"), secrets: .init(read: {
                engine.lock.withLock { engine.token }
            }, replace: { token in engine.lock.withLock { engine.token = token } }), makeDriver: { _, _, _, session, policy, _ in
                engine.driver(policy: policy, session: session)
            }, context: { folder, documents, intake, query, cancelled in
                try onRead(folder, cancelled)
                return .init(data: .obj([("fresh_query", .str(query)), ("documents", .bool(documents)), ("intake", .bool(intake))]),
                      sources: [.init(id: "S1", path: "documents/bylaw.txt", page: 2, revision: "invented-r1", text: "Pets require written permission.")])
            }, available: available)
        }
        func configure() async throws {
            _ = try await runtime.handle(.init([(key: "command", value: .str("claude_configure")), (key: "program", value: .str("/invented/claude")), (key: "credential", value: .str("invented-token"))]))
        }
        func request(_ command: String, _ fields: [(String, JSONValue)] = []) async throws -> JSONObject {
            try await runtime.handle(.init([(key: "command", value: .str(command)), (key: "binder", value: .str(folder.path))] + fields.map { (key: $0.0, value: $0.1) }))
        }
        func send(_ id: UUID, _ text: String) async throws -> JSONObject { try await request("chat_send", [("request_id", .str(id.uuidString)), ("text", .str(text))]) }
        func completed(_ id: UUID) async throws -> JSONObject {
            for _ in 0..<200 {
                let r = try await request("chat_poll", [("request_id", .str(id.uuidString))])
                if !["accepted", "running"].contains(r["phase"]?.stringValue ?? "") { return r }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ClaudeConversationRuntime.Refused.unavailable
        }
        func connect() async throws { try await configure(); _ = try await request("claude_enable", [("documents", .bool(true)), ("intake", .bool(true))]) }
    }

    @Test func enableDoesNotInventAccountOrScopeAndOnlyUsesTheFixedSetupCanary() async throws {
        let f = try Fixture()
        await #expect(throws: ClaudeConversationRuntime.Refused.self) { try await f.request("claude_enable") }
        try await f.configure()
        #expect(try await f.request("claude_binder")["enabled"] == .bool(false))
        #expect(f.engine.lock.withLock { f.engine.lines } == Array(repeating: "Read CURRENT_CHECK in the app's current policy and return only its exact value.", count: 2))
        #expect(f.engine.lock.withLock { f.engine.policies }.allSatisfy { !$0.contains("workshop") })
    }
    @Test func exactAcceptanceSurvivesLostRepliesWithoutASecondRunAndUsesFreshCurrentContext() async throws {
        let f = try Fixture(); try await f.connect()
        let id = UUID(), original = " Which bylaw covers pets?\n Keep the exact words. "
        let receipt = try await f.send(id, original), done = try await f.completed(id)
        #expect(done["phase"] == .str("replied") && done["text"] == .str(original))
        #expect(try await f.send(id, original)["turn_id"] == receipt["turn_id"])
        await #expect(throws: ClaudeConversationRuntime.Refused.self) { try await f.send(id, "Different words") }
        let next = UUID(); _ = try await f.send(next, "Use the newer current To-do state."); _ = try await f.completed(next)
        #expect(f.engine.lock.withLock { f.engine.lines.count } == 4)
        #expect(f.engine.lock.withLock { f.engine.resumes } == [false, false, false, false])
        #expect(f.engine.lock.withLock { Set(f.engine.sessions).count } == 4)
        #expect(f.engine.lock.withLock { f.engine.policies.last?.contains("newer current To-do state") } == true)
        let reply = try JSONParser.parse(try #require(done["reply"]?.stringValue)).value
        #expect(reply["citations"]?.arrayValue?.first?["path"] == .str("documents/bylaw.txt"))
        #expect(reply["task"]?["title"] == .str("Ask the board")) // Data only: no writer exists here.
    }
    @Test func activeStopWaitsForExitAndBusyNeverAcceptsAnotherLine() async throws {
        let f = try Fixture(); try await f.connect(); f.engine.lock.withLock { f.engine.hold = true }
        let id = UUID(), started = try await f.send(id, "Invented long reply")
        for _ in 0..<100 where !f.engine.lock.withLock({ f.engine.running }) { try await Task.sleep(for: .milliseconds(10)) }
        await #expect(throws: ClaudeConversationRuntime.Refused.self) { try await f.send(UUID(), "Keep this second draft") }
        _ = try await f.request("chat_stop", [("request_id", .str(id.uuidString)), ("turn_id", try #require(started["turn_id"]))])
        #expect(try await f.completed(id)["phase"] == .str("interrupted"))
        #expect(!f.engine.lock.withLock { f.engine.running })
    }

    @Test func anUpdatedVerifiedClaudeContinuesTheEnabledConversation() async throws {
        let f = try Fixture(); try await f.connect()
        let first = UUID(); _ = try await f.send(first, "Read the invented bylaw.")
        #expect(try await f.completed(first)["phase"] == .str("replied"))
        f.engine.lock.withLock { f.engine.hash = "updated-fixture-hash" }
        let next = UUID(); _ = try await f.send(next, "Continue after the Claude update.")
        #expect(try await f.completed(next)["phase"] == .str("replied"))
        #expect(f.engine.lock.withLock { f.engine.resumes } == [false, false, false, false])
        #expect(f.engine.lock.withLock { Set(f.engine.sessions).count } == 4)
    }
    @Test func disablingAndClearingDoNotReuseNativeContextOrEraseAnUnrelatedThread() async throws {
        let f = try Fixture(); try await f.connect(); let id = UUID()
        _ = try await f.send(id, "Invented earlier line"); _ = try await f.completed(id)
        _ = try await f.request("chat_clear")
        #expect(try await f.request("chat_history")["turns"] == .array([]))
        _ = try await f.request("claude_disable")
        await #expect(throws: ClaudeConversationRuntime.Refused.self) { try await f.send(UUID(), "Refuse this disabled scope") }
    }
    @Test func modelDataCannotInventCitationPathsOrSneakHeadersIntoAnAction() throws {
        let source = ClaudeBinderContext.Source(id: "S1", path: "documents/bylaw.txt", page: 2, revision: "r1", text: "Pets.")
        let raw = #"{"answer":"Invented answer","citations":["/outside","S1","S1"],"task":{"title":"Line\nbreak","details":"No"},"draft":{"to":"person@example.com\r\nBcc:outside@example.com","subject":"Hi","body":"Draft"}}"#
        let result = try JSONParser.parse(ClaudeBinderReply.normalize(raw, sources: [source])).value
        #expect(result["citations"]?.arrayValue?.count == 1)
        #expect(result["task"] == .null && result["draft"] == .null)
        #expect(ClaudeBinderContext.searchTerms("which by law talks about pet regulations").contains("pets"))
    }
    final class SourceReader: DocumentReader, @unchecked Sendable {
        let lock = NSLock()
        private var seen: [String] = []
        func revision(of document: DocumentRecord) -> String? { "invented-r1" }
        func read(_ document: DocumentRecord) -> DocumentText {
            lock.withLock { seen.append(document.path) }
            let text = document.path.hasPrefix("intake/") ? "From: workshopdesk@example.com\nSubject: Inspection reply\nPlease confirm Thursday." : "Pets require written board permission."
            return DocumentText(revision: "invented-r1", language: "en", pages: [(2, .read(text, from: "parsed"))])
        }
        var paths: [String] { lock.withLock { seen } }
    }
    @Test func sourcePacksFindPluralPetRulesWithPageCitationsAndRespectSeparateIntakeConsent() throws {
        let f = try Fixture(), reader = SourceReader()
        try AtomicFile.makePrivateFolder(f.folder.appendingPathComponent(".sprava"))
        try AtomicFile.makePrivateFolder(f.folder.appendingPathComponent("intake/mail"))
        try Data("Invented complete mail".utf8).write(to: f.folder.appendingPathComponent("intake/mail/notice.md"))
        try Data(#"{"meta":{"name":"workshop","schema_version":2},"open_items":[],"documents":[{"id":"D1","path":"references/bylaw.txt","title":"Governing charter"}],"processing_log":[]}"#.utf8).write(to: f.folder.appendingPathComponent("catalog.json"))
        let support = f.root.appendingPathComponent("index-support")
        let pack = try ClaudeBinderContext.build(folder: f.folder, support: support, documents: true, intake: true,
                                                 query: "which by law talks about pet regulations", reader: reader)
        #expect(pack.sources.contains { $0.path == "references/bylaw.txt" && $0.page == 2 })
        #expect(pack.sources.contains { $0.path == "intake/mail/notice.md" && $0.text.contains("workshopdesk@example.com") })
        let blindReader = SourceReader()
        let restricted = try ClaudeBinderContext.build(folder: f.folder, support: support, documents: false, intake: false,
                                                       query: "pet inspection", reader: blindReader)
        #expect(blindReader.paths.isEmpty)
        #expect(restricted.sources.isEmpty)
        #expect(!JSONWriter.compact(restricted.data).contains("workshopdesk@example.com"))
        #expect(restricted.data["document_inventory"] == .array([]))
    }

    @Test func theOriginalPersonLineIsDurableBeforeDocumentIndexingBegins() async throws {
        final class Proof: @unchecked Sendable {
            let lock = NSLock()
            var scope: UUID?
            var sawReceipt = false
        }
        let proof = Proof(), request = UUID(), text = "Find the pet bylaw, keeping this original request."
        let f = try Fixture(onRead: { folder, _ in
            let scope = try #require(proof.lock.withLock { proof.scope })
            let ledger = try ConversationTurnStore(at: folder.deletingLastPathComponent().appendingPathComponent("support/binder-store/conversation.sqlite"))
            let accepted = try ledger.record(conversationID: scope, requestID: request)
            proof.lock.withLock { proof.sawReceipt = accepted?.text == text }
        })
        try await f.connect()
        let scope = try #require(try await f.request("claude_binder")["binder_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        proof.lock.withLock { proof.scope = scope }
        _ = try await f.send(request, text); _ = try await f.completed(request)
        #expect(proof.lock.withLock { proof.sawReceipt })
    }

    @Test func aTurnsFileChangesComeWithItsReplyAndCanBeUndone() async throws {
        let f = try Fixture(); try await f.connect()
        let notes = f.folder.appendingPathComponent("notes.md"), old = f.folder.appendingPathComponent("old.md")
        try Data("first".utf8).write(to: notes); try Data("unneeded".utf8).write(to: old)
        f.engine.lock.withLock { f.engine.act = {
            try? Data("second".utf8).write(to: notes); try? FileManager.default.removeItem(at: old)
        } }
        let id = UUID()
        let turn = try #require(try await f.send(id, "Tidy this invented binder.")["turn_id"]?.stringValue)
        let done = try await f.completed(id)
        #expect(done["phase"] == .str("replied"))
        #expect(done["changes"]?["summary"] == .str("Changed 1 file, deleted 1 file: notes.md, old.md"))
        #expect(done["changes"]?["undone"] == .bool(false))
        // The saved conversation shows the same line after a restart.
        #expect(try await f.request("chat_history")["turns"]?.arrayValue?.first?["changes"]?["summary"] == done["changes"]?["summary"])
        // A later edit refuses, leaving everything as it is.
        try Data("the person's words".utf8).write(to: notes)
        let refused = try await f.request("chat_undo", [("turn_id", .str(turn))])
        #expect(refused["undone"] == .bool(false) && refused["conflicts"] == .array([.str("notes.md")]))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        try Data("second".utf8).write(to: notes)
        #expect(try await f.request("chat_undo", [("turn_id", .str(turn))])["undone"] == .bool(true))
        #expect(try Data(contentsOf: notes) == Data("first".utf8))
        #expect(try Data(contentsOf: old) == Data("unneeded".utf8))
        #expect(try await f.request("chat_poll", [("request_id", .str(id.uuidString))])["changes"]?["undone"] == .bool(true))
    }

    @Test func aFolderACommandClosedIsReopenedSoItsTurnIsStillRecorded() async throws {
        let f = try Fixture(); try await f.connect()
        let closed = f.folder.appendingPathComponent("closed"), notes = f.folder.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: false)
        try Data("first".utf8).write(to: notes)
        f.engine.lock.withLock { f.engine.act = {
            try? FileManager.default.removeItem(at: notes)
            _ = chmod(closed.path, 0)
        } }
        let id = UUID(); let turn = try #require(try await f.send(id, "Tidy.")["turn_id"]?.stringValue)
        let done = try await f.completed(id)
        #expect(done["changes"]?["summary"] == .str("Deleted 1 file: notes.md"))
        #expect(try await f.request("chat_undo", [("turn_id", .str(turn))])["undone"] == .bool(true))
        #expect(try Data(contentsOf: notes) == Data("first".utf8))
    }

    @Test func aTurnThatCouldNotBeRecordedSaysSoAndOffersNoUndo() async throws {
        let f = try Fixture(); try await f.connect()
        let binder = try #require(try await f.request("claude_binder")["binder_id"]?.stringValue)
        let head = f.root.appendingPathComponent("support/binder-store/history/\(binder)/head.json")
        f.engine.lock.withLock { f.engine.act = { try? Data("not json".utf8).write(to: head) } }
        let id = UUID(); let turn = try #require(try await f.send(id, "Tidy.")["turn_id"]?.stringValue)
        let done = try await f.completed(id)
        #expect(done["phase"] == .str("replied"))
        #expect(done["changes"]?["undoable"] == .bool(false))
        #expect(done["changes"]?["summary"]?.stringValue?.contains("could not record") == true)
        await #expect(throws: (any Error).self) { try await f.request("chat_undo", [("turn_id", .str(turn))]) }
    }

    @Test func aTurnThatChangesNothingHasNoLineAndTheBadUndosAreRefused() async throws {
        let f = try Fixture(); try await f.connect()
        let id = UUID(); _ = try await f.send(id, "Only a question."); let done = try await f.completed(id)
        #expect(done["changes"] == nil)
        await #expect(throws: (any Error).self) { try await f.request("chat_undo", [("turn_id", .str("not-a-turn"))]) }
        await #expect(throws: (any Error).self) { try await f.request("chat_undo", [("turn_id", .str(UUID().uuidString))]) }
    }

    @Test func anUndoWaitsForARunningTurn() async throws {
        let f = try Fixture(); try await f.connect()
        let id = UUID(); let first = try #require(try await f.send(id, "First.")["turn_id"]?.stringValue); _ = try await f.completed(id)
        f.engine.lock.withLock { f.engine.hold = true }
        let next = UUID(); _ = try await f.send(next, "Second.")
        await #expect(throws: ClaudeConversationRuntime.Refused.busy) { try await f.request("chat_undo", [("turn_id", .str(first))]) }
        f.engine.lock.withLock { f.engine.hold = false }
        _ = try await f.completed(next)
    }

    @Test func removingABinderForgetsItsHistoryCopies() async throws {
        let f = try Fixture(); try await f.connect()
        let id = UUID(); _ = try await f.send(id, "Keep a baseline."); _ = try await f.completed(id)
        let binder = try #require(try await f.request("claude_binder")["binder_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let history = f.root.appendingPathComponent("support/binder-store/history/\(binder.uuidString)")
        #expect(FileManager.default.fileExists(atPath: history.path))
        let ticket = try await f.runtime.beginLifecycle(folder: f.folder)
        await f.runtime.finishLifecycle(ticket)
        #expect(!FileManager.default.fileExists(atPath: history.path))
    }

    @Test func aBinderThatIsNotConnectedSaysWhy() async throws {
        let f = try Fixture(); try await f.configure()
        #expect(try await f.request("claude_binder")["reason"] == .str("new"))
        _ = try await f.request("claude_enable")
        #expect(try await f.request("claude_binder")["enabled"] == .bool(true))
        #expect(try await f.request("claude_binder")["reason"] == nil)
        _ = try await f.request("claude_disable")
        #expect(try await f.request("claude_binder")["reason"] == .str("disconnected"))
        _ = try await f.request("claude_enable")
        let moved = f.root.appendingPathComponent("workshop-moved")
        try FileManager.default.moveItem(at: f.folder, to: moved)
        let state = try await f.runtime.handle(.init([(key: "command", value: .str("claude_binder")), (key: "binder", value: .str(moved.path))]))
        #expect(state["enabled"] == .bool(false) && state["reason"] == .str("moved"))
    }

    @Test func aBinderBeingOffloadedOrOffTheShelfIsNotOfferedAConnection() async throws {
        let f = try Fixture(available: { _ in false }); try await f.configure()
        #expect(try await f.request("claude_binder")["reason"] == .str("unavailable"))
        struct Damaged: Error {}
        let g = try Fixture(available: { _ in throw Damaged() }); try await g.configure()
        #expect(try await g.request("claude_binder")["reason"] == .str("unavailable"))
    }

    @Test func disconnectedConversationStaysReadableAndClearableWithoutModelConsent() async throws {
        let f = try Fixture(); try await f.connect(); let id = UUID()
        _ = try await f.send(id, "Keep this invented local history."); _ = try await f.completed(id)
        _ = try await f.request("claude_disable")
        #expect(try await f.request("claude_binder")["enabled"] == .bool(false))
        #expect(try await f.request("chat_history")["turns"]?.arrayValue?.first?["text"] == .str("Keep this invented local history."))
        _ = try await f.request("chat_clear")
        #expect(try await f.request("chat_history")["turns"] == .array([]))
    }
    @Test func stopDuringIndexingPreventsAnyNewModelTurnAndPreservesTheAcceptedLine() async throws {
        final class Gate: @unchecked Sendable {
            let semaphore = DispatchSemaphore(value: 0)
            let lock = NSLock(); var started = false
        }
        let gate = Gate(), f = try Fixture(onRead: { _, _ in
            gate.lock.withLock { gate.started = true }
            _ = gate.semaphore.wait(timeout: .now() + 2)
        })
        try await f.connect(); let id = UUID(), record = try await f.send(id, "Find the invented source.")
        for _ in 0..<100 where !gate.lock.withLock({ gate.started }) { try await Task.sleep(for: .milliseconds(5)) }
        _ = try await f.request("chat_stop", [("request_id", .str(id.uuidString)), ("turn_id", try #require(record["turn_id"]))])
        #expect(try await f.completed(id)["phase"] == .str("interrupted"))
        #expect(f.engine.lock.withLock { f.engine.lines.count } == 2) // Setup checks only, no binder/model turn.
        gate.semaphore.signal()
    }

    @Test(arguments: ["Intake/mail/notice.md", "INTAKE/mail/notice.md"])
    func catalogAliasesCannotBypassIntakeConsent(_ path: String) throws {
        let f = try Fixture(), reader = SourceReader()
        try AtomicFile.makePrivateFolder(f.folder.appendingPathComponent(".sprava"))
        let catalog: JSONValue = .obj([("meta", .obj([("name", .str("workshop")), ("schema_version", .int(2))])),
            ("open_items", .array([])), ("processing_log", .array([])),
            ("documents", .array([.obj([("id", .str("D1")), ("path", .str(path)), ("title", .str("Unshared intake subject"))])]))])
        try Data(JSONWriter.compact(catalog).utf8).write(to: f.folder.appendingPathComponent("catalog.json"))
        let pack = try ClaudeBinderContext.build(folder: f.folder, support: f.root.appendingPathComponent("index-support"),
                                                 documents: true, intake: false, query: "pets", reader: reader)
        #expect(reader.paths.isEmpty)
        #expect(pack.sources.isEmpty)
        #expect(pack.data["document_inventory"] == .array([]))
    }

    @Test func removingABinderFencesItsQueuedReadBeforeAcknowledgingTheShelfChange() async throws {
        final class Read: @unchecked Sendable {
            let lock = NSLock(); var began = false; var writerCalled = false
        }
        let read = Read(), f = try Fixture(onRead: { _, cancelled in
            read.lock.withLock { read.began = true }
            for _ in 0..<100 where !cancelled() { usleep(5_000) }
        })
        try await f.connect(); let id = UUID()
        let scope = try #require(try await f.request("claude_binder")["binder_id"]?.stringValue)
        let home = f.root.appendingPathComponent("support/brains/read-homes/" + scope)
        try AtomicFile.makePrivateFolder(home)
        try Data("Invented native context".utf8).write(to: home.appendingPathComponent("fixture.txt"))
        _ = try await f.send(id, "Find the invented bylaw.")
        for _ in 0..<100 where !read.lock.withLock({ read.began }) { try await Task.sleep(for: .milliseconds(5)) }
        let request = JSONWriter.compact(.obj([("command", .str("shelf_remove")), ("binder", .str(f.folder.path))]))
        let answer = await f.runtime.routeAppRequest(request) { _ in
            read.lock.withLock { read.writerCalled = true }
            return #"{"ok":true}"#
        }
        #expect(try JSONParser.parse(answer).value["ok"] == .bool(true))
        #expect(read.lock.withLock { read.writerCalled })
        #expect(f.engine.lock.withLock { f.engine.lines.count } == 2) // Only account canaries.
        #expect(try await f.completed(id)["phase"] == .str("interrupted"))
        #expect(!FileManager.default.fileExists(atPath: home.path))
        #expect(try await f.request("claude_binder")["enabled"] == .bool(false))
    }

}
