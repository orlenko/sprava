import BinderFormat
import BinderStore
@testable import Brains
import Capture
import Darwin
import Extract
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the first review of the rebuilt Brains layer: a private document's reading is never shown to a
/// brain, a card file that is a FIFO or a link never holds or misleads a retry, get_proposal believes only a card as
/// Sprava wrote it, and a client that stops taking replies loses its connection. Binders, Sprava's state and the
/// socket live in temporary folders only. Invented data only.
@Suite(.serialized) struct BrainsReview3Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let bb = BugbotMCPTests()
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])
    let docID = "estate-example-doc-2026-009"

    // MARK: - 1. A private document's reading, in every tool

    /// The privacy states a waiting reading's document can be in, and whether a brain may see the reading.
    enum State: String, CaseIterable, Sendable, CustomStringConvertible {
        case plain                    // nothing private anywhere: the control
        case filedPrivate             // filed by the person as private
        case markerRemovedOutside     // filed private, then the marker removed by an outside edit
        case loweredByThePerson       // filed private, then the person's own op removed the marker
        case markedPrivateOutside     // filed plain, then marked private by an outside edit (a narrowing)
        case unknownSensitivity       // a sensitivity value Sprava does not know
        case privateWithoutID         // marked private outside, its id dropped (path and digest kept)
        case privateWrongIDSamePath   // marked private outside under another id and digest, same path
        case privateSameDigestMoved   // marked private outside, moved and its id dropped (digest kept)
        case privateRecordUnplaced    // an outside record marked private with neither id, digest nor path
        case cardPrivate              // the filing card is private (a private capture, a raise)
        case cardFilesItPrivate       // the filing card files the document as private
        case cardChangedOutside       // the filing card is no longer as Sprava wrote it

        var description: String { rawValue }
        var shown: Bool { [.plain, .loweredByThePerson].contains(self) }
    }

    struct Env {
        let s: BugbotMCPTests.Setup
        let sha: String
    }

    func editDocument(_ folder: URL, _ change: (inout [String: Any]) -> Void) throws {
        let url = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var docs = try #require(catalog["documents"] as? [[String: Any]])
        let i = try #require(docs.firstIndex { $0["id"] as? String == docID })
        change(&docs[i])
        catalog["documents"] = docs
        try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted]).write(to: url)
    }

    /// The person files the intake letter at once, plain or private.
    func file(_ e: Env, sensitivity: String?) throws {
        var document = JSONObject([(key: "id", value: .string(docID)), (key: "title", value: .str("Invented letter")),
                                   (key: "path", value: .str("documents/letter.pdf")), (key: "sha256", value: .string(e.sha))])
        if let sensitivity { document.set("sensitivity", .string(sensitivity)) }
        let op = TekaStore.OpBody(op: "file_document", args: JSONObject([(key: "document", value: .object(document)),
                                                                         (key: "from", value: .str("intake/letter.pdf"))]), actor: user)
        _ = try TekaStore(folder: e.s.folder).apply([op], now: now)
    }

    /// A binder at full disclosure, a client that may read documents, an intake letter, its filing card (trusted) and
    /// its careful reading waiting, then the state applied.
    func env(_ state: State) throws -> Env {
        let s = try bb.setup(documents: true) { c in
            var meta = c["meta"] as? [String: Any] ?? [:]
            meta["disclosure"] = "full"
            c["meta"] = meta
        }
        let intake = s.folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("An invented letter about a roof.".utf8).write(to: intake.appendingPathComponent("letter.pdf"))
        let sha = try #require(DocumentPaths.sha256(of: intake.appendingPathComponent("letter.pdf")))
        let e = Env(s: s, sha: sha)

        var document = JSONObject([(key: "id", value: .str("$new:1")), (key: "title", value: .str("Invented letter")),
                                   (key: "path", value: .str("documents/letter.pdf")), (key: "sha256", value: .string(sha))])
        if state == .cardFilesItPrivate { document.set("sensitivity", .str("private")) }
        let body = JSONObject([(key: "op", value: .str("file_document")),
                               (key: "args", value: .obj([("document", .object(document)), ("from", .str("intake/letter.pdf"))]))])
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(s.commands.client))])
        var card = Proposal.make(title: "File the invented letter", actor: actor, ops: [body], now: now)
        if state == .cardPrivate {
            var prov = card.raw["provenance"]?.objectValue ?? JSONObject()
            prov.set("private", .bool(true))
            card.raw.set("provenance", .object(prov))
        }
        try ProposalStore.save(card, in: s.folder)
        try s.commands.trustProposals([card.id], in: s.folder)

        var r = IntakeReadings.Entry(id: "reading-1", binder: s.folder.standardizedFileURL.path, name: "letter.pdf", sha256: sha,
                                     card: card.id,
                                     reading: IntakeReading(kind: "text", textFrom: "parsed", text: "An invented letter about a roof.", channel: "other"),
                                     now: now)
        r.escalation = "waiting"
        r.result = JSONObject([(key: "class", value: .str("letter")), (key: "title", value: .str("Invented roof letter")),
                               (key: "summary", value: .str("An invented summary."))])
        try IntakeReadings(support: s.commands.support).save(r)

        switch state {
        case .plain, .cardPrivate, .cardFilesItPrivate:
            break
        case .filedPrivate:
            try file(e, sensitivity: "private")
        case .markerRemovedOutside:
            try file(e, sensitivity: "private")
            try editDocument(s.folder) { $0["sensitivity"] = nil }
        case .loweredByThePerson:
            try file(e, sensitivity: "private")
            let lower = TekaStore.OpBody(op: "update_document", args: JSONObject([(key: "id", value: .string(docID)),
                                                                                  (key: "unset", value: .array([.str("sensitivity")]))]), actor: user)
            _ = try TekaStore(folder: s.folder).apply([lower], now: now)
        case .markedPrivateOutside:
            try file(e, sensitivity: nil)
            try editDocument(s.folder) { $0["sensitivity"] = "private" }
        case .unknownSensitivity:
            try file(e, sensitivity: nil)
            try editDocument(s.folder) { $0["sensitivity"] = "confidential" }
        case .privateWithoutID:
            try file(e, sensitivity: nil)
            try editDocument(s.folder) { $0["sensitivity"] = "private"; $0["id"] = nil }
        case .privateWrongIDSamePath:
            try file(e, sensitivity: nil)
            try editDocument(s.folder) { d in
                d["sensitivity"] = "private"; d["id"] = "estate-example-doc-2026-999"; d["sha256"] = String(repeating: "cd", count: 32)
            }
        case .privateSameDigestMoved:
            try file(e, sensitivity: nil)
            try editDocument(s.folder) { $0["sensitivity"] = "private"; $0["id"] = nil; $0["path"] = "documents/moved.pdf" }
        case .privateRecordUnplaced:
            let url = s.folder.appendingPathComponent("catalog.json")
            var catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            catalog["documents"] = (catalog["documents"] as? [[String: Any]] ?? []) + [["title": "Invented note", "sensitivity": "private"]]
            try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted]).write(to: url)
        case .cardChangedOutside:
            var raw = card.raw
            raw.set("title", .str("File the invented letter, changed"))
            try Data(JSONWriter.pretty(.object(raw)).utf8).write(to: ProposalStore.dir(s.folder).appendingPathComponent("\(card.id).json"))
        }
        return e
    }

    @Test(arguments: State.allCases) func aReadingIsShownOnlyWhileItsDocumentIsNotPrivate(_ state: State) throws {
        let e = try env(state)
        let s = e.s
        #expect(!Teka.read(s.folder).federationBlocked, "the binder itself stays visible")
        #expect(try bb.tool(s.server, "list_binders", .obj([]))["structuredContent"]?["binders"]?.arrayValue?.count == 1)

        let listed = try bb.tool(s.server, "list_readings", .obj([]))["structuredContent"]?["readings"]?.arrayValue ?? []
        #expect(listed.contains { $0["reading_id"] == .str("reading-1") } == state.shown)
        if !state.shown {
            let text = JSONWriter.compact(.array(listed))
            for leak in ["Invented roof letter", "An invented summary.", "letter.pdf"] { #expect(!text.contains(leak)) }
        }

        let ref = JSONValue.obj([("binder", .str("estate-example")), ("reading_id", .str("reading-1"))])
        let read = try bb.tool(s.server, "read_document", ref)
        #expect(read["isError"] == .bool(!state.shown))
        #expect((read["structuredContent"]?["text"]?.stringValue == "An invented letter about a roof.") == state.shown)

        let readings = IntakeReadings(support: s.commands.support)
        if state.shown {
            let finished = try bb.tool(s.server, "finish_reading", ref)
            #expect(finished["isError"] == .bool(false))
            #expect(readings.load("reading-1")?.escalation == "answered")
        } else {
            // A remembered id opens nothing: the reading can be neither answered nor taken off the queue.
            let answer = try bb.tool(s.server, "propose_ops", .obj([("binder", .str("estate-example")), ("title", .str("Invented answer")),
                                                                    ("ops", .array([bb.addItem(1)])), ("reading_id", .str("reading-1"))]))
            #expect(answer["isError"] == .bool(true))
            #expect(try bb.tool(s.server, "finish_reading", ref)["isError"] == .bool(true))
            #expect(readings.load("reading-1")?.escalation == "waiting")
        }
    }

    @Test func privateDocumentsFollowTheRatchet() throws {
        // An outside edit that removes a marker Sprava applied waits; one that adds a marker counts at once; only the
        // person's own op lowers it; an aborted op confirms nothing.
        let a = String(repeating: "ab", count: 32), other = String(repeating: "cd", count: 32)
        let doc = { (sens: String?) -> JSONValue in
            var o: [(String, JSONValue)] = [("id", .str("d-1")), ("path", .str("documents/a.pdf")), ("sha256", .string(a.uppercased()))]
            if let sens { o.append(("sensitivity", .string(sens))) }
            return .obj(o)
        }
        let catalogWith = { (d: [JSONValue]) in JSONObject([(key: "documents", value: .array(d))]) }
        let snapshot = JSONObject([(key: "id", value: .str("o-0")), (key: "op", value: .str("import_snapshot")),
                                   (key: "args", value: .obj([("catalog", .obj([("documents", .array([]))]))]))])
        let fileAs = { (sens: String?) in JSONObject([(key: "id", value: .str("o-1")), (key: "op", value: .str("file_document")),
                                                      (key: "actor", value: .obj([("kind", .str("clerk"))])),
                                                      (key: "args", value: .obj([("document", doc(sens)), ("from", .str("intake/a.pdf"))]))]) }
        let lowerBy = { (kind: String) in JSONObject([(key: "id", value: .str("o-2")), (key: "op", value: .str("update_document")),
                                                      (key: "actor", value: .obj([("kind", .string(kind))])),
                                                      (key: "args", value: .obj([("id", .str("d-1")), ("unset", .array([.str("sensitivity")]))]))]) }
        let abort = JSONObject([(key: "id", value: .str("o-3")), (key: "op", value: .str("abort")),
                                (key: "args", value: .obj([("ops", .array([.str("o-1")]))]))])
        func docs(_ d: [JSONValue], _ ops: [JSONObject]) throws -> MCPServer.PrivateDocuments {
            try #require(MCPServer.privateDocuments(catalog: catalogWith(d), ops: ops))
        }

        let removedOutside = try docs([doc(nil)], [snapshot, fileAs("private")])
        #expect(removedOutside.digests == [a])
        #expect(removedOutside.paths.contains(DocumentPaths.fold("intake/a.pdf")))
        #expect(try docs([doc(nil)], [snapshot, fileAs("private"), lowerBy("brain")]).digests == [a])
        #expect(try docs([doc(nil)], [snapshot, fileAs("private"), lowerBy("user")]).digests.isEmpty)
        #expect(try docs([doc(nil)], [snapshot, fileAs("private"), abort]).digests.isEmpty)
        #expect(try docs([doc("private")], [snapshot]).digests == [a])
        #expect(try docs([doc("unmarked")], [snapshot]).digests.isEmpty)
        #expect(MCPServer.isPrivate(.str("anything else")))
        #expect(!MCPServer.isPrivate(nil) && !MCPServer.isPrivate(.null))
        #expect(MCPServer.digest(.string("sha256:" + a.uppercased())) == a && MCPServer.digest(.str("ab")) == nil)

        // A private record counts by its own digest and path, whatever its id says (filed plain by Sprava first).
        let filed = [snapshot, fileAs(nil)]
        let noID = JSONValue.obj([("path", .str("documents/a.pdf")), ("sha256", .string(a)), ("sensitivity", .str("private"))])
        #expect(try docs([noID], filed).digests.contains(a))
        #expect(try docs([noID], filed).paths.contains(DocumentPaths.fold("intake/a.pdf")))
        let wrongIDSamePath = JSONValue.obj([("id", .str("d-9")), ("path", .str("documents/a.pdf")), ("sha256", .string(other)),
                                             ("sensitivity", .str("private"))])
        // Tied by its path to d-1, filed from intake/a.pdf with digest a.
        #expect(try docs([wrongIDSamePath], filed).digests.isSuperset(of: [a, other]))
        let sameDigestOtherPath = JSONValue.obj([("path", .str("documents/moved.pdf")), ("sha256", .string(a)), ("sensitivity", .str("private"))])
        #expect(try docs([sameDigestOtherPath], filed).paths.contains(DocumentPaths.fold("intake/a.pdf")))
        // A private record with neither a digest nor a path: placed by its id's history, or nothing is shown.
        let bare = JSONValue.obj([("id", .str("d-1")), ("title", .str("Invented")), ("sensitivity", .str("private"))])
        #expect(try docs([bare], filed).digests.contains(a))
        let unknown = JSONValue.obj([("title", .str("Invented")), ("sensitivity", .str("private"))])
        #expect(MCPServer.privateDocuments(catalog: catalogWith([unknown]), ops: filed) == nil)
        let unknownID = JSONValue.obj([("id", .str("d-7")), ("sha256", .int(1)), ("sensitivity", .str("private"))])
        #expect(MCPServer.privateDocuments(catalog: catalogWith([unknownID]), ops: filed) == nil)
    }

    // MARK: - finish_reading keeps its note

    @Test func finishReadingKeepsItsNote() throws {
        let e = try env(.plain)
        let s = e.s
        let ref = { (note: JSONValue) in JSONValue.obj([("binder", .str("estate-example")), ("reading_id", .str("reading-1")), ("note", note)]) }
        let readings = IntakeReadings(support: s.commands.support)
        #expect(try bb.tool(s.server, "finish_reading", ref(.int(3)))["isError"] == .bool(true))
        #expect(try bb.tool(s.server, "finish_reading", ref(.string(String(repeating: "x", count: MCPServer.noteLimit + 1))))["isError"] == .bool(true))
        #expect(readings.load("reading-1")?.escalation == "waiting")

        let r = try bb.tool(s.server, "finish_reading", ref(.str("An invented letter that needs no reply.")))
        #expect(r["isError"] == .bool(false))
        let kept = try #require(readings.load("reading-1"))
        #expect(kept.escalation == "answered" && kept.answer == "none")
        #expect(kept.result?["brain_note"]?["text"]?.stringValue == "An invented letter that needs no reply.")
        #expect(kept.result?["brain_note"]?["client"]?.stringValue == "claude-code-1")
        #expect(kept.result?["summary"]?.stringValue == "An invented summary.")
    }

    // MARK: - 2. A card file that is a FIFO or a link never holds or misleads a retry

    func retry(_ s: BugbotMCPTests.Setup) throws -> JSONValue {
        try bb.propose(s.server, ops: [bb.addItem(1)], requestID: "invented-request-9")
    }

    @Test func aFIFOAmongTheCardsRefusesTheRetryWithoutBlocking() throws {
        let s = try bb.setup()
        let dir = ProposalStore.dir(s.folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = Proposal.make(title: "x", actor: JSONObject(), ops: [], now: now).id
        #expect(mkfifo(dir.appendingPathComponent("\(id).json").path, 0o600) == 0)
        // On another thread, so a regression fails the test instead of hanging the suite.
        nonisolated(unsafe) var reply: JSONValue?
        let done = DispatchSemaphore(value: 0)
        Thread { reply = try? retry(s); done.signal() }.start()
        #expect(done.wait(timeout: .now() + 10) == .success, "the retry blocked on a FIFO")
        #expect(reply?["isError"] == .bool(true))
        #expect(reply?["structuredContent"]?["error"]?.stringValue?.contains("cannot all be read") == true)
        // Without a request_id nothing is looked up, and the card is made.
        #expect(try bb.propose(s.server, ops: [bb.addItem(1)])["isError"] == .bool(false))
    }

    @Test func aLinkedCardFileRefusesTheRetry() throws {
        let s = try bb.setup()
        // A card outside the binder that claims to be this request's, linked in under a valid name.
        let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .string(s.commands.client)),
                                (key: "model", value: .str("claude-code-1"))])
        var card = Proposal.make(title: "Invented card", actor: actor, ops: [], now: now)
        card.raw.set("request_id", .str("invented-request-9"))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-brains-outside-\(UUID().uuidString).json")
        try Data(JSONWriter.pretty(.object(card.raw)).utf8).write(to: outside)
        let dir = ProposalStore.dir(s.folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("\(card.id).json"), withDestinationURL: outside)

        let r = try retry(s)
        #expect(r["isError"] == .bool(true))
        #expect(r["structuredContent"]?["error"]?.stringValue?.contains("cannot all be read") == true)
        // The file outside is untouched and the link is still a link: nothing was written through it.
        #expect(try Data(contentsOf: outside) == Data(JSONWriter.pretty(.object(card.raw)).utf8))
        var st = stat()
        #expect(lstat(dir.appendingPathComponent("\(card.id).json").path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK)
    }

    // MARK: - 3. get_proposal believes only the card as Sprava wrote it

    @Test func getProposalRefusesACardChangedOutside() throws {
        let s = try bb.setup()
        let made = try bb.propose(s.server, ops: [bb.addItem(1)])
        let id = try #require(made["structuredContent"]?["proposal_id"]?.stringValue)
        let ask = JSONValue.obj([("binder", .str("estate-example")), ("proposal_id", .string(id))])
        #expect(try bb.tool(s.server, "get_proposal", ask)["structuredContent"]?["state"] == .str("proposed"))

        // Another program marks it applied: no op was applied, so the brain must not be told it was.
        let url = ProposalStore.dir(s.folder).appendingPathComponent("\(id).json")
        var raw = try #require(try JSONParser.parse(Data(contentsOf: url)).value.objectValue)
        raw.set("state", .str("applied"))
        raw.set("applied_ops", .array([.str("invented-op")]))
        try Data(JSONWriter.pretty(.object(raw)).utf8).write(to: url)
        let r = try bb.tool(s.server, "get_proposal", ask)
        #expect(r["isError"] == .bool(true))
        #expect(r["structuredContent"]?["state"] == nil)
    }

    // MARK: - 4. A client that stops taking replies loses its connection

    @Test func aClientThatTakesNoRepliesIsClosed() throws {
        // Short, so the socket path stays under the 104-byte limit.
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spb3-\(UUID().uuidString.prefix(8))")
        var clients = MCPClients()
        let token = try clients.register(id: "invented-1", name: "Invented", binders: [:], now: now)
        try clients.save(support)
        let logged = LockedLines()
        let listener = MCPListener(support: support, commands: Commands(support: support, deviceID: "t"),
                                   queue: DispatchQueue(label: "test.mcp-b3"), shelf: { [] }, log: { logged.append($0) })
        listener.writeSeconds = 1
        try listener.start()
        defer { listener.stop() }
        let fd = try MCPShimConnection.connect(socket: listener.socketURL.path, clientID: "invented-1", token: token).get()
        defer { close(fd) }
        #expect(listener.openConnections == 1)

        // Requests, and never a reply read: the replies fill the socket until the runtime's write stalls.
        setSendTimeout(fd, seconds: 1)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        // Until the runtime stops taking requests too (its own write stalled): the first write that fails ends it.
        for _ in 0..<2_000 { guard writeLine(fd, request, deadline: Date().addingTimeInterval(2)) else { break } }

        let deadline = Date().addingTimeInterval(15)
        while listener.openConnections > 0, Date() < deadline { usleep(50_000) }
        #expect(listener.openConnections == 0, "a stalled connection kept its slot")
        #expect(logged.lines.contains { $0.contains("closed=reply_not_taken") })
    }
}

/// Log lines collected from the listener's threads.
final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}
