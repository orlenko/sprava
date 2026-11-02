import AppKit
import Foundation
import SpravaKit
import Testing
@testable import SpravaApp

@MainActor @Suite struct ConversationSharingTests {
    @MainActor final class Server {
        let binder = UUID().uuidString, ticket = UUID().uuidString
        var calls: [JSONObject] = []
        var failAt: Int?
        var total = 205
        var hold: CheckedContinuation<Void, Never>?
        var shouldHold = false
        var malformed = false
        var wrongBinder = false
        var duplicate = false
        func answer(_ text: String) async throws -> String {
            let request = try #require(JSONParser.parse(text).value.objectValue); calls.append(request)
            if shouldHold { await withCheckedContinuation { hold = $0 } }
            let after = Int(request["after"]?.numberValue?.safeInteger ?? 0)
            if failAt == after { throw ConversationSharing.Failure.incomplete }
            let end = min(after + 100, total)
            let rows = (after..<end).map { n in record(duplicate ? 0 : n) }
            return JSONWriter.compact(.obj([("ok", .bool(true)), ("binder_id", .str(wrongBinder ? UUID().uuidString : binder)), ("export_id", .str(ticket)),
                ("after", .int(end)), ("count", .int(total)), ("done", .bool(malformed || end == total)), ("turns", .array(rows))]))
        }
        func record(_ n: Int) -> JSONValue {
            // Stable invented ids make duplicates detectable without relying on fixture names.
            let request = String(format: "00000000-0000-4000-8000-%012d", n)
            let turn = String(format: "00000001-0000-4000-8000-%012d", n)
            let reply = JSONWriter.compact(.obj([("answer", .str("Workshop answer \(n)\n```swift\n  let note = \"café 🎵\"\n```")),
                ("hidden_prompt", .str("EXCLUDED CONTEXT")), ("provider_frame", .str("EXCLUDED FRAME"))]))
            return .obj([("binder_id", .str(binder)), ("request_id", .str(request)), ("turn_id", .str(turn)),
                         ("text", .str("Workshop question \(n)\nKeep this line.")), ("phase", .str("replied")), ("reply", .str(reply))])
        }
    }
    @Test func copyPagesEveryTurnInOrderAndUsesOnlyVisibleText() async throws {
        let server = Server(), folder = URL(fileURLWithPath: "/invented/workshop")
        var copied = ""
        let sharing = ConversationSharing(client: RuntimeClient(answer: { try await server.answer($0) }), copy: { copied = $0; return true })
        await sharing.share(.clipboard, folder: folder, scope: server.binder, entries: [], cards: [:], stillSelected: { true })
        #expect(copied.components(separatedBy: "\nYou\n").count == 205)
        #expect(copied.contains("You\nWorkshop question 0\nKeep this line.\n\nClaude\nWorkshop answer 0\n```swift\n  let note = \"café 🎵\"\n```"))
        #expect(copied.contains("Workshop answer 204") && !copied.contains("EXCLUDED"))
        #expect(server.calls.count == 3 && server.calls.allSatisfy { $0["command"] == .str("chat_export") && $0["binder"] == .str(folder.path) })
        #expect(sharing.message == "Conversation copied privately for 60 seconds.")
    }
    @Test func errorsAndSilentPartialPagesNeverCopyOrSaveAndKeepDrafts() async {
        for failure in 0..<4 {
            let server = Server(); server.failAt = failure == 0 ? 100 : nil
            server.malformed = failure == 1; server.wrongBinder = failure == 2; server.duplicate = failure == 3
            var outputs = 0
            let sharing = ConversationSharing(client: RuntimeClient(answer: { try await server.answer($0) }), copy: { _ in outputs += 1; return true }, save: { _ in outputs += 1; return true })
            await sharing.share(.clipboard, folder: URL(fileURLWithPath: "/invented/workshop"), scope: server.binder, entries: [], cards: [:], stillSelected: { true })
            #expect(outputs == 0 && sharing.message?.contains("complete conversation could not") == true)
        }
    }
    @Test func changingBindersWhileReadingCannotCopyThePreviousBinder() async throws {
        let server = Server(); server.shouldHold = true; server.total = 1
        var selected = true, copies = 0
        let sharing = ConversationSharing(client: RuntimeClient(answer: { try await server.answer($0) }), copy: { _ in copies += 1; return true })
        let task = Task { await sharing.share(.clipboard, folder: URL(fileURLWithPath: "/invented/workshop"), scope: server.binder, entries: [], cards: [:], stillSelected: { selected }) }
        for _ in 0..<100 where server.hold == nil { await Task.yield() }
        #expect(server.hold != nil); selected = false; server.hold?.resume(); await task.value
        #expect(copies == 0 && !sharing.busy)
    }
    @Test func cancelClipboardFailureAndWriteFailureLeaveRealModelDraftAndThreadIntact() async {
        let server = Server(); server.total = 1
        let folder = URL(fileURLWithPath: "/invented/workshop")
        let chat = BinderChat(commands: nil, binderID: { _ in server.binder }, readHistory: { _ in ([], nil) })
        await chat.show(folder); chat.draft = "Unsent score notes 🎵"
        for failure in 0..<3 {
            var output = ""
            let sharing = ConversationSharing(client: RuntimeClient(answer: { try await server.answer($0) }), copy: { output = $0; return false }, save: { text in
                output = text
                if failure == 2 { throw CocoaError(.fileWriteNoPermission) }
                return false
            })
            await sharing.share(failure == 0 ? .clipboard : .file, folder: folder, scope: server.binder, entries: chat.entries, cards: [:], stillSelected: { true })
            #expect(chat.draft == "Unsent score notes 🎵" && chat.entries.isEmpty && !output.contains(chat.draft))
            #expect(failure == 1 ? sharing.message == nil : sharing.message != nil)
        }
    }
    @Test func structuredSuggestionsAndIncompleteStatesAreReadableAndNeverRawJSON() throws {
        let request = UUID(), turn = UUID()
        let reply = JSONWriter.compact(.obj([("answer", .str("Check the workshop schedule.")),
            ("citations", .array([.obj([("path", .str("documents/schedule.txt")), ("page", .int(2))])])),
            ("task", .obj([("title", .str("Tune the cello")), ("details", .str("Use the spare strings."))])),
            ("draft", .obj([("to", .str("workshop@example.invalid")), ("subject", .str("Rehearsal")), ("body", .str("Hello,\n  Tuesday works."))])),
            ("hidden_prompt", .str("DO NOT COPY"))]))
        let complete: JSONValue = .obj([("request_id", .str(request.uuidString)), ("turn_id", .str(turn.uuidString)), ("text", .str("Explain the schedule")), ("phase", .str("replied")), ("reply", .str(reply))])
        let text = try ConversationTranscript.text(rows: [complete], entries: [], cards: [:])
        #expect(text.contains("Sources:\ndocuments/schedule.txt, page 2") && text.contains("Suggested To-do:\nTune the cello"))
        #expect(text.contains("Email draft — not sent\nTo: workshop@example.invalid") && !text.contains("DO NOT COPY") && !text.contains("{\"answer\""))
        for phase in ["accepted", "running", "interrupted", "failed"] {
            var row = try #require(complete.objectValue)
            row = JSONObject(row.entries.filter { $0.key != "phase" && $0.key != "reply" } + [(key: "phase", value: .str(phase))])
            let entry = BinderChat.Entry(id: turn, speaker: .binder, text: "Partial visible text", state: .replying)
            let snapshot = try ConversationTranscript.text(rows: [.object(row)], entries: [entry], cards: [:])
            #expect(snapshot.contains("Partial visible text") && snapshot.contains("incomplete"))
        }
    }
}
