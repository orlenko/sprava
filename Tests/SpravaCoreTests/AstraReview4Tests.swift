import CryptoKit
import Darwin
import Foundation
import Testing
@testable import SpravaCore

/// Regressions from the fourth adversarial review of increment 1 (key and credential files in intake, hub
/// withdrawal while the outbox fails, private corrections that close items, correction cards that could not be
/// kept, unreadable op logs, exhausted id sequences) and the MCP socket's modes. Invented data only.
@Suite(.serialized) struct AstraReview4Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func journal(_ s: PSetup) -> String { (try? String(contentsOf: s.inbox.journalURL, encoding: .utf8)) ?? "" }

    // MARK: - 1. Key and credential files are never read

    @Test func keyFileNamesFollowTheBinderRule() {
        for name in ["secret.pem", "Server.KEY", "cert.p12", "cert.pfx", "id_rsa", "id_ed25519.pub", "id_ecdsa", "backup.age",
                     "age-identity.txt", ".netrc", "credentials.json", "Credentials-2026.txt", "token-api.json", "login.keychain-db",
                     ".env", ".env.local", "intake/mail/sub/id_rsa"] {
            #expect(DocumentPaths.isKeyFile(name), "\(name)")
        }
        for name in ["notice.txt", "keynote.pdf", "monkey.pdf", "tokens.txt", "environment.md", "levy.pdf", "pemberton.pdf"] {
            #expect(!DocumentPaths.isKeyFile(name), "\(name)")
        }
    }

    @Test func aCredentialFileInIntakeIsHeldUnread() throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        try t.write(s, "credentials.json", #"{"password": "INVENTED-SECRET-4410"}"#)
        let result = t.card(s)
        #expect(result.carded == 1 && result.held == 1)
        let card = try #require(t.open(s).first)
        #expect(card.title.hasPrefix("Held:"))
        let intake = card.raw["provenance"]?["intake"]
        #expect(intake?["held"]?.stringValue?.contains("key or credential file") == true)
        #expect(intake?["preview"] == nil && intake?["facts"] == nil)
        #expect(!JSONWriter.compact(.object(card.raw)).contains("INVENTED-SECRET"))
        // Nothing waits for the clerk or a brain; the person can still file it.
        #expect(IntakeReadings(support: s.support).all().isEmpty)
        #expect(card.ops.map { $0["op"]?.stringValue } == ["file_document"])
    }

    @Test func aKeyFileInAMessagesAttachmentsFolderHoldsTheMessage() throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        try t.write(s, "mail/levy.md", IntakeReadingTests.message)
        try t.write(s, "mail/levy attachments/id_ed25519", "INVENTED-SECRET-5520")
        try t.write(s, "mail/levy attachments/notice.txt", IntakeReadingTests.notice)
        #expect(t.card(s).held == 1)
        let card = try #require(t.open(s).first)
        #expect(card.title.hasPrefix("Held:"))
        #expect(card.raw["provenance"]?["intake"]?["held"]?.stringValue?.contains("id_ed25519") == true)
        #expect(IntakeReadings(support: s.support).all().isEmpty)
        #expect(card.ops.count == 3)   // the message and both attachments can still be filed
    }

    @Test func aKeyFileInsideAnEmailIsSkippedWithANote() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra4-eml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func part(_ name: String, _ text: String) -> String {
            """
            --XYZ
            Content-Type: application/octet-stream; name="\(name)"
            Content-Disposition: attachment; filename="\(name)"
            Content-Transfer-Encoding: base64

            \(Data(text.utf8).base64EncodedString())
            """
        }
        let eml = """
        From: Invented Manager <manager@example.com>
        To: person@example.com
        Subject: Invented access details
        Date: Tue, 6 Oct 2026 09:00:00 -0400
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain; charset=utf-8

        The notice is attached.
        \(part("token-api.json", "INVENTED-SECRET-6630"))
        \(part(".netrc", "machine example.com password INVENTED-SECRET-6631"))
        \(part("notice.txt", "Invented notice text"))
        --XYZ--
        """
        let url = folder.appendingPathComponent("message.eml")
        try Data(eml.utf8).write(to: url)
        let r = IntakeReading.read(url, channel: "email", reader: .inProcess)
        #expect(r.held == nil)
        #expect(!r.text.contains("INVENTED-SECRET"))
        #expect(r.text.contains("Invented notice text"))
        #expect(r.notes.filter { $0.contains("key or credential file") }.count == 2, "\(r.notes)")
    }

    // MARK: - 2. A drain that fails never holds back a withdrawal

    @Test func aBrokenOutboxDoesNotKeepAWithdrawnSliceOnTheHub() throws {
        let ops = BugbotOpsTests()
        let c = ops.commands()
        let (folder, spool) = try ops.readyBinder(c)
        let slice = ops.sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        let outbox = spool.appendingPathComponent("outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("{ not json".utf8).write(to: outbox.appendingPathComponent("rental-elm-street.intake.json"))
        #expect(throws: (any Error).self) { try HubLane.drain(folder, root: spool, now: now) }

        // A redaction narrows the projection: published although the drain fails.
        _ = try ops.apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("redact", .bool(true)), ("kind", .str("payment"))]))]))
        let narrowed = HubLane.sync(folder, root: spool, now: now)
        #expect(narrowed.drainError != nil && narrowed.failed)
        guard case .published? = narrowed.published else { Issue.record("not published: \(String(describing: narrowed.publishError))"); return }
        let titles = try JSONParser.parse(try Data(contentsOf: slice)).value["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
        #expect(titles.contains("[redacted]"))

        // Disclosure none withdraws the slice although the drain fails.
        try ops.outsideEdit(folder, ops.setMeta("disclosure", .str("none")))
        let withdrawn = HubLane.sync(folder, root: spool, now: now)
        #expect(withdrawn.drainError != nil)
        #expect(withdrawn.published == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }

    // MARK: - 3. A private correction never closes an item in the clear

    @Test func aPrivateCorrectionRedactsBeforeItDrops() throws {
        let s = try pSetup()
        let adapter = "11111111-2222-4333-8444-5555555555d1"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "R1", revision: "rev1", text: "Call the roofer\nOrder the blinds")
        try bFileAndApprove(s)
        let blinds = try #require(Teka.read(s.folder).items.compactMap(\.object).first { $0["title"] == .str("Order the blinds") })
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "R1", revision: "rev2", text: "Call the roofer") {
            $0.set("sensitivity", .str("private"))
        }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let card = try #require(pOpen(s).first { $0.title.contains("corrected") })
        let onBlinds = card.ops.filter { $0["args"]?["id"] == blinds["id"] }
        #expect(onBlinds.map { $0["op"]?.stringValue } == ["update_item", "drop"])
        #expect(onBlinds.first?["args"]?["set"]?["redact"] == .bool(true))
        #expect(onBlinds.first?["args"]?["set"]?["kind"] == .str("other"))

        // Approved before the separate redaction card, the closure still carries the redaction to the hub.
        _ = try TekaStore(folder: s.folder).approve(card, now: pNow)
        let closure = try #require(Teka.read(s.folder).catalog?["processing_log"]?.arrayValue?.last { $0["id"] == blinds["id"] })
        #expect(closure["final"]?["redact"] == .bool(true))
        let catalog = try #require(Teka.read(s.folder).catalog)
        var closed = closure["final"]?.objectValue ?? JSONObject()
        closed.set("id", blinds["id"]!)
        closed.set("title", closure["title"] ?? .str(""))
        let (slice, _) = try HubLane.project(catalog: catalog, folderName: s.folder.lastPathComponent, closedOnce: [closed],
                                             key: .init(size: .bits256), now: pNow)
        #expect(!JSONWriter.compact(slice).contains("blinds"))
    }

    // MARK: - 4. A correction card that could not be kept is tried again, once

    /// A note from an adapter whose two lines were filed and approved, then a public revision that changes both.
    func correctedNote(_ s: PSetup, ref: String) throws -> String {
        let adapter = "11111111-2222-4333-8444-5555555555d2"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: "rev1", text: "Call the roofer\nOrder the blinds")
        try bFileAndApprove(s)
        return try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: "rev2",
                          text: "Call the roofer on Monday\nOrder the blinds on Friday")
    }

    func corrections(_ folder: URL, of event: String) -> [Proposal] {
        ProposalStore.list(in: folder).map(\.0).filter { CaptureInbox.isCorrection($0, of: event) && $0.state == "proposed" }
    }

    @Test func aCorrectionCardThatCannotBeSavedIsRetried() throws {
        let s = try pSetup()
        let event = try correctedNote(s, ref: "R2")
        let proposals = ProposalStore.dir(s.folder)
        chmod(proposals.path, 0o500)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        chmod(proposals.path, 0o700)
        #expect(try s.inbox.readState().ingested[event] == "ingested")
        #expect(corrections(s.folder, of: event).isEmpty)
        #expect(journal(s).contains("card_failed"))

        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(try s.inbox.readState().ingested[event] == "proposed")
        let made = corrections(s.folder, of: event)
        #expect(made.count == 1)
        #expect(made.allSatisfy { s.commands.isTrusted($0.id, in: s.folder) })
    }

    @Test func aCorrectionCardThatCannotBeTrustedIsRemovedAndRetried() throws {
        let s = try pSetup()
        let event = try correctedNote(s, ref: "R3")
        let runtime = s.support.appendingPathComponent("runtime")
        chmod(runtime.path, 0o500)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        chmod(runtime.path, 0o700)
        #expect(try s.inbox.readState().ingested[event] == "ingested")
        // No card is left that could never be approved.
        #expect(corrections(s.folder, of: event).isEmpty)

        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let made = corrections(s.folder, of: event)
        #expect(made.count == 1)
        #expect(made.allSatisfy { s.commands.isTrusted($0.id, in: s.folder) })
    }

    @Test func aRetryAfterAPartialFailureMakesNoSecondCard() async throws {
        let s = try pSetup()
        let b = BugbotCaptureTests()
        let (first, second, _, adapter) = try await b.splitNote(s, titles: ("Call the roofer", "Order the blinds"))
        let event = try pEvent(s, device: adapter, app: "adapter", ref: "S1", revision: "rev2",
                               text: "Call the roofer on Monday\nOrder the blinds on Friday")
        let rows = { [b.row(first), b.row(second)] }
        // The first binder's card is kept; the second binder's cannot be saved.
        chmod(ProposalStore.dir(second).path, 0o500)
        _ = s.inbox.sweep(binders: rows(), commands: s.commands, now: pNow)
        chmod(ProposalStore.dir(second).path, 0o700)
        #expect(try s.inbox.readState().ingested[event] == "ingested")
        #expect(corrections(first, of: event).count == 1)
        #expect(corrections(second, of: event).isEmpty)

        _ = s.inbox.sweep(binders: rows(), commands: s.commands, now: pNow)
        #expect(try s.inbox.readState().ingested[event] == "proposed")
        #expect(corrections(first, of: event).count == 1)
        #expect(corrections(second, of: event).count == 1)
    }

    // MARK: - 5. An op log that cannot be read is never taken for none

    @Test func anUnreadableOpLogStopsAdoptionBeforeAnyWrite() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        // A binder never adopted has no log: that alone is an empty one.
        #expect(try store.readOpLog().ops.isEmpty)
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("first"))]), now: now)
        let sprava = folder.appendingPathComponent(".sprava")
        let names = ["ops.ndjson", "owner.json", "snapshot.json", "adopted/catalog.json"]
        let before = try names.map { try Data(contentsOf: sprava.appendingPathComponent($0)) }

        let log = sprava.appendingPathComponent("ops.ndjson")
        chmod(log.path, 0o200)
        defer { chmod(log.path, 0o600) }
        #expect(throws: TekaStore.Refused.self) { try store.readOpLog() }
        #expect(throws: TekaStore.Refused.self) {
            try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("second"))]), now: now)
        }
        chmod(log.path, 0o600)
        #expect(try names.map { try Data(contentsOf: sprava.appendingPathComponent($0)) } == before)
    }

    // MARK: - 6. An exhausted id sequence is an error, never a crash

    @Test func anExhaustedSequenceIsRefused() throws {
        func catalog(_ id: String) throws -> JSONObject {
            try #require(try JSONParser.parse(#"{"meta":{"name":"example"},"open_items":[{"id":"\#(id)"}]}"#).value.objectValue)
        }
        #expect(throws: TekaStore.Refused.self) {
            try IDMint.next(catalog: try catalog("example-2026-9223372036854775807"), opLog: [], year: 2026)
        }
        // Another year's sequence is untouched, and a number past 32 bits is written out whole.
        #expect(try IDMint.next(catalog: try catalog("example-2026-9223372036854775807"), opLog: [], year: 2027) == "example-2027-001")
        #expect(try IDMint.next(catalog: try catalog("example-2026-4294967296"), opLog: [], year: 2026) == "example-2026-4294967297")
        // Approving a new item there is refused, not a trap.
        let add = JSONObject([(key: "op", value: .str("add_item")),
                              (key: "args", value: .obj([("item", .obj([("id", .str("$new:1")), ("title", .str("Invented task"))]))]))])
        #expect(throws: TekaStore.Refused.self) {
            try Placeholders.resolve([add], catalog: try catalog("example-2026-9223372036854775807"), opLog: [], year: 2026, at: "2026-10-06T00:00:00Z")
        }
    }

    // MARK: - 7. The MCP socket's modes come from chmod, never from the process umask

    @Test func theSocketIsPrivateInAPrivateFolder() throws {
        // Short, so the socket path stays under the 104-byte limit.
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sp4-\(UUID().uuidString.prefix(8))")
        let listener = MCPListener(support: support, commands: Commands(support: support, deviceID: "t"), queue: DispatchQueue(label: "test.mcp4"),
                                   shelf: { [] }, log: { _ in })
        try listener.start()
        defer { listener.stop() }
        var st = stat()
        #expect(lstat(listener.socketURL.path, &st) == 0)
        #expect(st.st_mode & S_IFMT == S_IFSOCK)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(lstat(listener.socketURL.deletingLastPathComponent().path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
    }
}
