import BinderFormat
import BinderStore
import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The clerk job knows the person's own addresses from their email connections, so mail they wrote is filed with no
/// to-dos and its card says to whom they wrote (issue #594). Temporary folders and invented mail only.
@Suite(.serialized) struct OwnMailClerkJobTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    static func message(from: String) -> String {
        """
        ---
        subject: "Invoice"
        from: "\(from)"
        to: "Invented Supplier <supplier@example.com>"
        date: "Thu, 01 Oct 2026 23:30:00 -0400"
        ---
        Could you please send the invoice this week? Let me know if anything is missing.
        """
    }

    /// An adopted binder with one email in intake, carded by code, and a connection for `user` when one is given.
    func setup(from: String, connection user: String?, others: [String] = []) throws -> (Commands, URL) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-own-mail-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        try adoptAsCommand(folder, commands: commands, now: now, today: today)
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: now) }
        let url = folder.appendingPathComponent("intake/mail/2026-10-01_12_invoice.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.message(from: from).utf8).write(to: url)
        if let user {
            let account = try #require(IMAPAccount(host: "mail.example.invalid", port: 993, security: .tls, user: user))
            _ = try BinderIMAPConnections(support: support, hash: { "fixture" }).configure(folder: folder, account: account, mailbox: "Sent",
                                                                                                   ownAddresses: others)
        }
        let watcher = IntakeWatcher(support: support)
        let rows = [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))]
        _ = watcher.scan(binders: rows, commands: commands, now: now, requireReading: true)
        let prepared = watcher.prepare(binders: rows, deviceID: "dev", reader: .inProcess)
        _ = watcher.scan(binders: rows, commands: commands, now: now, prepared: prepared, requireReading: true)
        return (commands, folder)
    }

    func run(_ c: Commands, _ folder: URL) throws -> Proposal {
        let ask = JSONValue.obj([("quote", .str("Could you please send the invoice")), ("title", .str("Send the invoice")),
                                 ("action", .str("send")), ("when_text", .str("this week"))])
        let model = ScriptedModel(extractions: [.obj([("items", .array([ask]))])], contextSize: 8192)
        model.document = .obj([("class", .str("action")), ("title", .str("")), ("date_text", .str("")),
                               ("summary", .str("An email about an invoice.")), ("reply_needed", .bool(true))])
        let context = JobContext(support: c.support, commands: c, rows: { Shelf.rows(registry: nil, picked: [folder]) }, commandQueue: nil, log: { _ in })
        #expect(ClerkJob.run(context, model: .success(model)).read == 1)
        let cards = ProposalStore.list(in: folder).map(\.0).filter { $0.state == "proposed" }
        #expect(cards.count == 1)
        return try #require(cards.first)
    }

    @Test func mailFromAConnectedAccountIsFiledWithNoToDos() throws {
        let (c, folder) = try setup(from: "Invented Person <Me@Example.Invalid>", connection: "me@example.invalid")
        let card = try run(c, folder)
        #expect(card.raw["provenance"]?["filed_by"] == .str("clerk"))
        #expect(card.ops.map { $0["op"] } == [.str("file_document")])
        let review = card.review(describe: { _ in "" })
        #expect(review["summary"]?.stringValue?.hasPrefix("You wrote this to supplier@example.com, so no to-dos are proposed from it.") == true)
        #expect(review["warnings"]?.arrayValue?.contains(.str("A reply may be needed.")) == false)
    }

    @Test func mailFromAnOtherAddressThePersonGaveIsTheirsToo() throws {
        let (c, folder) = try setup(from: "Invented Person <me@example.invalid>", connection: "login-name", others: ["ME@example.invalid"])
        let card = try run(c, folder)
        #expect(card.ops.map { $0["op"] } == [.str("file_document")])
        #expect(card.review(describe: { _ in "" })["summary"]?.stringValue?.hasPrefix("You wrote this to supplier@example.com") == true)
    }

    @Test func mailFromSomeoneElseStillProposesToDos() throws {
        let (c, folder) = try setup(from: "Invented Supplier <supplier@example.com>", connection: "me@example.invalid")
        let card = try run(c, folder)
        #expect(card.ops.contains { $0["op"] == .str("add_item") })
        #expect(card.review(describe: { _ in "" })["summary"] == .str("An email about an invoice."))
    }
}

/// With an engine for the binder, it reads the intake document in the clerk's place, and the log names it with fixed
/// words only (decisions.md D40). Invented mail only.
@Suite(.serialized) struct EngineClerkJobTests {
    final class Engine: DocumentEngine, @unchecked Sendable {
        let name = "Claude"
        let reply: Result<JSONValue, ClerkModelError>
        init(_ reply: Result<JSONValue, ClerkModelError>) { self.reply = reply }
        func answer(instructions: String, prompt: String) async throws -> JSONValue { try reply.get() }
    }

    func run(_ engine: Engine?) throws -> (Proposal, [String]) {
        let own = OwnMailClerkJobTests()
        let (c, folder) = try own.setup(from: "Invented Supplier <supplier@example.com>", connection: nil)
        let model = ScriptedModel(extractions: [], contextSize: 8192)
        model.document = .obj([("class", .str("action")), ("title", .str("")), ("date_text", .str("")),
                               ("summary", .str("The clerk's summary.")), ("reply_needed", .bool(false))])
        let lines = LockedLines()
        let context = JobContext(support: c.support, commands: c, rows: { Shelf.rows(registry: nil, picked: [folder]) }, commandQueue: nil,
                                 log: { lines.append($0) })
        let expected = folder.standardizedFileURL.path
        #expect(ClerkJob.run(context, model: .success(model), engine: { asked in
            asked.standardizedFileURL.path == expected ? engine : nil
        }).read == 1)
        let card = try #require(ProposalStore.list(in: folder).map(\.0).first { $0.state == "proposed" })
        return (card, lines.all)
    }

    final class LockedLines: @unchecked Sendable {
        private let lock = NSLock(); private var lines: [String] = []
        func append(_ s: String) { lock.withLock { lines.append(s) } }
        var all: [String] { lock.withLock { lines } }
    }

    @Test func anEngineReadsTheDocumentAndTheCardSaysSo() throws {
        let ask = JSONValue.obj([("quote", .str("Could you please send the invoice")), ("title", .str("Send the invoice")),
                                 ("action", .str("send")), ("when_text", .str("this week"))])
        let (card, lines) = try run(Engine(.success(.obj([("class", .str("action")), ("title", .str("")), ("date_text", .str("")),
                                                          ("summary", .str("A supplier asks for the invoice.")), ("reply_needed", .bool(false)),
                                                          ("items", .array([ask]))]))))
        let review = card.review(describe: { _ in "" })
        #expect(review["summary"] == .str("A supplier asks for the invoice."))
        #expect(card.raw["provenance"]?["reading"]?["read_by"] == .str("Claude"))
        #expect(card.ops.contains { $0["op"] == .str("add_item") })
        #expect(lines.contains { $0.hasPrefix("clerk document ") && $0.contains(" read_by=Claude ") })
    }

    @Test func aFailedEngineLeavesTheClerkAndLogsOnlyTheReason() throws {
        let (card, lines) = try run(Engine(.failure(.unavailable("daily cap"))))
        let review = card.review(describe: { _ in "" })
        #expect(review["summary"] == .str("The clerk's summary."))
        #expect(card.raw["provenance"]?["reading"]?["read_by"] == nil)
        #expect(lines.contains { $0.contains(" engine_failure=unavailable__daily_cap__ ") })
    }

    @Test func noEngineIsTheClerkAsBefore() throws {
        let (card, lines) = try run(nil)
        #expect(card.review(describe: { _ in "" })["summary"] == .str("The clerk's summary."))
        #expect(!lines.contains { $0.contains("read_by") || $0.contains("engine_failure") })
    }
}
