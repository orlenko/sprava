import BinderFormat
import Brains
import Capture
import Extract
import Foundation
import Retrieval
@testable import Services
import SpravaKit
import Testing

@Suite struct IMAPConversationWorkflowTests {
    @Test func importedMailIsSearchableDraftGroundedAndTaskWrittenOnlyOnPersonConfirmation() throws {
        let (commands, folder) = try DirectAddTests().adopted()
        let support = commands.support
        let connections = try BinderIMAPConnections(support: support, hash: { "fixture" })
        let connection = try connections.configure(folder: folder, account: IMAPAccount(host: "mail.example.invalid", port: 993, security: .tls, user: "resident@example.invalid")!, mailbox: "Labels/Workshop", sender: "manager@")
        // The worker baselines, then acknowledges one complete message.
        _ = try IMAPIntakeImport.run(connection, support: support, connections: connections, fetch: { _, cwd, _ in
            try Data("{\"uid_validity\":7,\"last_seen_uid\":1}".utf8).write(to: cwd.appendingPathComponent("state.json"))
        }, reader: .inProcess)
        #expect(try IMAPIntakeImport.run(connection, support: support, connections: connections, fetch: { _, cwd, target in
            let mail = "From: manager@example.invalid\r\nTo: resident@example.invalid\r\nSubject: Pet permission\r\nDate: Sat, 24 Oct 2026 12:30:00 +0000\r\n\r\nPlease confirm your request for written pet permission.\r\n"
            try Data(mail.utf8).write(to: target.appendingPathComponent("mail-1.eml"))
            try Data("{\"uid_validity\":7,\"last_seen_uid\":1}".utf8).write(to: cwd.appendingPathComponent("state.json"))
        }, reader: .inProcess) == 1)
        try AtomicFile.write(Data("Workshop bylaws, section 8: Pets require written permission from the board.\n".utf8), to: folder.appendingPathComponent("intake/pet-bylaws.txt"))
        let reader = HelperDocumentReader(binder: folder, reader: .inProcess) // Invented bytes only.
        let pack = try ClaudeBinderContext.build(folder: folder, support: support, documents: false, intake: true,
            query: "Which by law talks about pet regulations? Draft a reply to the manager and suggest a To-do.", reader: reader)
        let bylaw = try #require(pack.sources.first { $0.path == "intake/pet-bylaws.txt" })
        let email = try #require(pack.sources.first { $0.path.hasSuffix("-7-1.md") })
        #expect(bylaw.text.contains("section 8")); #expect(bylaw.page == 1)
        #expect(email.text.contains("From: manager@example.invalid"))
        let title = "Request written pet permission"
        let suggested = JSONWriter.compact(.obj([
            ("answer", .str("Section 8 requires written board permission.")), ("citations", .array([.str(bylaw.id), .str(email.id)])),
            ("draft", .obj([("to", .str("manager@example.invalid")), ("subject", .str("Re: Pet permission")), ("body", .str("Please consider my request for written permission under section 8."))])),
            ("task", .obj([("title", .str(title)), ("details", .str("Follow up with the board.")), ("due", .str("2026-10-28")), ("priority", .str("high"))]))
        ]))
        let card = try JSONParser.parse(ClaudeBinderReply.normalize(suggested, sources: pack.sources)).value
        #expect(card["draft"]?["recipient_in_sources"] == .bool(true))
        #expect(card["citations"]?.arrayValue?.contains { $0["path"] == .str(bylaw.path) && $0["page"] == .int(1) } == true)
        #expect(!Teka.read(folder).items.contains { $0.title == title }) // A suggestion did not write.
        let scope = try ClaudeReadConnections(at: support.appendingPathComponent("brains/read-scopes.sqlite")).enable(folder: folder, documents: false, intake: true)
        let saved = try DirectAddTests().call(commands, [
            ("command", .str("apply")), ("binder", .str(folder.path)), ("conversation_binding", .str(scope.id.uuidString)),
            ("op", .str("add_item")), ("args", .obj([("item", .obj([("id", .str("$new:1")), ("title", .str(title)),
                ("status", .str("open")), ("due", .str("2026-10-28")), ("priority", .str("high")), ("sensitivity", .str("private"))]))]))
        ])
        #expect(saved["ok"] == .bool(true))
        let task = try #require(Teka.read(folder).items.first { $0.title == title })
        #expect(task.due?.description == "2026-10-28")
        #expect(task.object?["priority"] == .str("high") && task.object?["sensitivity"] == .str("private"))
    }
}
