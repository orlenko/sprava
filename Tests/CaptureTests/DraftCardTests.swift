import BinderStore
@testable import Capture
import Foundation
import SpravaKit
import Testing

/// A draft card proposes; its message is built at approval from the binder's filed documents; an approved draft waits
/// in a private request until it is placed (decisions.md D41, integrations.md §5.2). Invented binders and mail only.
@Suite struct DraftCardTests {
    let now = Date(timeIntervalSince1970: 1_791_460_800)
    let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("claude"))])

    func binder() throws -> (URL, JSONObject) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-draft-card-\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("documents"), withIntermediateDirectories: true)
        try Data("Invented plan.".utf8).write(to: folder.appendingPathComponent("documents/plan.txt"))
        try Data("Invented private notice.".utf8).write(to: folder.appendingPathComponent("documents/notice.txt"))
        let catalog = JSONObject([(key: "documents", value: .array([
            .obj([("path", .str("documents/plan.txt"))]),
            .obj([("path", .str("documents/notice.txt")), ("sensitivity", .str("private"))]),
        ]))])
        return (folder, catalog)
    }

    let draft = DraftCard(to: ["supplier@example.com"], cc: ["office@example.com"], subject: "Invoice for October",
                          body: "Hello,\n\nPlease find the invoice attached.\n", attachments: [.init(path: "documents/plan.txt", isPrivate: false),
                                                                                                .init(path: "documents/notice.txt", isPrivate: false)],
                          inReplyTo: "<thread-1@example.com>", references: ["<thread-1@example.com>"])

    @Test func theCardIsOneLogEntryWithTheFieldsAndMarksPrivateDocuments() throws {
        let (_, catalog) = try binder()
        let p = try draft.proposal(actor: actor, catalog: catalog, now: now)
        #expect(p.ops.count == 1 && p.ops[0]["op"] == .str("add_log_entry"))
        let action = p.ops[0]["args"]?["entry"]?["action"]?.stringValue ?? ""
        #expect(action == "Email draft to supplier@example.com: Invoice for October")
        #expect(!action.contains("Please find"))
        let back = try #require(DraftCard(p))
        #expect(back.to == draft.to && back.cc == draft.cc && back.subject == draft.subject && back.body == draft.body)
        #expect(back.attachments.map(\.isPrivate) == [false, true])
        #expect(back.inReplyTo == "<thread-1@example.com>" && back.references == ["<thread-1@example.com>"])
        // A card that is no draft has no fields.
        #expect(DraftCard(Proposal.make(title: "Invented", actor: actor, ops: [], now: now)) == nil)
    }

    @Test func whatACardMayNotHoldIsRefusedByFieldNeverByValue() throws {
        let (_, catalog) = try binder()
        func refused(_ change: (inout DraftCard) -> Void) -> DraftCard.Refused? {
            var d = draft
            change(&d)
            do { _ = try d.proposal(actor: actor, catalog: catalog, now: now); return nil } catch { return error as? DraftCard.Refused }
        }
        #expect(refused { $0.to = [] } == .field("To"))
        #expect(refused { $0.to = ["two@example.com, three@example.com"] } != nil)
        #expect(refused { $0.subject = "Line one\r\nBcc: hidden@example.com" } != nil)
        #expect(refused { $0.inReplyTo = "not-an-id" } != nil)
        #expect(refused { $0.body = String(repeating: "x", count: DraftCard.maxBody + 1) } == .field("Body"))
        // Only documents filed in this binder: nothing outside it, nothing unfiled, no path that leaves it.
        #expect(refused { $0.attachments = [.init(path: "intake/mail.eml", isPrivate: false)] } == .attachment(0))
        #expect(refused { $0.attachments = [.init(path: "../outside.txt", isPrivate: false)] } == .attachment(0))
        #expect(refused { $0.attachments = [.init(path: "/etc/hosts", isPrivate: false)] } == .attachment(0))
        // A key or credential file is never attached, even one the catalog lists.
        var keyed = catalog
        keyed.set("documents", .array([.obj([("path", .str("documents/signing.key"))]), .obj([("path", .str("documents/credentials.json"))])]))
        for path in ["documents/signing.key", "documents/credentials.json"] {
            var d = draft; d.attachments = [.init(path: path, isPrivate: false)]
            #expect(throws: DraftCard.Refused.attachment(0)) { try d.proposal(actor: actor, catalog: keyed, now: now) }
        }
    }

    @Test func theMessageIsBuiltAtApprovalFromTheFilesAsTheyAreThen() throws {
        let (folder, catalog) = try binder()
        let id = UUIDv7.make(now: now)
        let message = try draft.message(card: id, from: "me@example.invalid", folder: folder, catalog: catalog, now: now)
        let text = String(decoding: message, as: UTF8.self)
        #expect(text.contains("Message-ID: \(DraftCard.messageID(card: id))\r\n"))
        #expect(text.contains("To: supplier@example.com\r\n") && text.contains("In-Reply-To: <thread-1@example.com>\r\n"))
        #expect(text.contains("plan.txt") && text.contains("notice.txt"))
        #expect(text.contains(Data("Invented private notice.".utf8).base64EncodedString()))
        // A document gone, or replaced by a link, since the card was written is not attached: the approval fails.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("documents/notice.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("documents/notice.txt"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: DraftCard.Refused.attachment(1)) { try draft.message(card: id, from: "me@example.invalid", folder: folder, catalog: catalog, now: now) }
        // A folder of the binder that is a link to one elsewhere never leads a read out of it.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-draft-outside-\(UUID())")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("Outside the binder.".utf8).write(to: outside.appendingPathComponent("report.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("documents/export"), withDestinationURL: outside)
        var linked = catalog
        linked.set("documents", .array([.obj([("path", .str("documents/export/report.txt"))])]))
        var through = draft; through.attachments = [.init(path: "documents/export/report.txt", isPrivate: false)]
        #expect(throws: DraftCard.Refused.attachment(0)) { try through.message(card: id, from: "me@example.invalid", folder: folder, catalog: linked, now: now) }
        // Attachments over 18 MiB together are refused, never cut.
        try Data(count: 18 * 1024 * 1024).write(to: folder.appendingPathComponent("documents/plan.txt"))
        var big = draft; big.attachments = [draft.attachments[0], .init(path: "documents/plan.txt", isPrivate: false)]
        try FileManager.default.removeItem(at: folder.appendingPathComponent("documents/notice.txt"))
        #expect(throws: DraftCard.Refused.tooLarge) { try big.message(card: id, from: "me@example.invalid", folder: folder, catalog: catalog, now: now) }
    }

    @Test func aRequestIsWrittenBeforeApprovalAndReadyAfter() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-draft-requests-\(UUID())")
        let requests = DraftRequests(support: support)
        let id = UUIDv7.make(now: now)
        let binder = URL(fileURLWithPath: "/invented/binder")
        try requests.begin(id: id, binder: binder, message: Data("Message-ID: <a@b>\r\n\r\nx".utf8))
        #expect(requests.all() == [.init(id: id, binder: "/invented/binder", state: .approving, failure: nil)])
        try requests.ready(id: id)
        #expect(requests.all().first?.state == .ready)
        try requests.failed(id: id, reason: "no drafts folder")
        #expect(requests.all().first == .init(id: id, binder: "/invented/binder", state: .failed, failure: "no drafts folder"))
        #expect(try requests.message(id: id) == Data("Message-ID: <a@b>\r\n\r\nx".utf8))
        // Private: the folder and its files are the person's alone.
        var info = stat()
        #expect(lstat(requests.root.appendingPathComponent(id).path, &info) == 0 && info.st_mode & 0o077 == 0)
        try requests.remove(id: id)
        #expect(requests.all().isEmpty)
        // A name that is no card id is never a folder, and an unreadable request is never placed.
        #expect(throws: DraftRequests.Refused.invalidID) { try requests.begin(id: "../escape", binder: binder, message: Data()) }
        try FileManager.default.createDirectory(at: requests.root.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        #expect(requests.all().isEmpty)
    }
}
