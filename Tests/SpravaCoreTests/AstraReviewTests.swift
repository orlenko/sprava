import Darwin
import Foundation
import Testing
@testable import SpravaCore

/// Regressions from the adversarial review of increment 1 (proposal ids, privacy raises, offload, readings,
/// state files that cannot be read, the clerk's and the Inbox's hand-overs, the document reader, MCP logs).
/// Invented data only.
@Suite(.serialized) struct AstraReviewTests {
    let clerk = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("none"))])
    let garbage = Data("{\"broken".utf8)

    func note(_ s: PSetup, _ text: String, hint: String? = nil) throws -> String {
        let n = try s.producer.prepareNote(text, binderHint: hint, startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: n.id, digest: n.digest)
        try s.producer.publish(n)
        return n.id
    }

    func call(_ s: PSetup, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj(fields)), now: pNow, today: today)).value
    }

    func listed(_ s: PSetup, _ id: String) throws -> JSONValue? {
        try call(s, [("command", .str("proposals")), ("binder", .string(s.folder.path))])["proposals"]?.arrayValue?.first { $0["id"] == .string(id) }
    }

    func op(_ name: String, _ args: [(String, JSONValue)]) -> JSONObject {
        JSONObject([(key: "op", value: .string(name)), (key: "args", value: .obj(args))])
    }

    // MARK: - 1. A proposal id names a file only when it is a UUID

    @Test func proposalIDsNeverReachOutsideTheirFolder() throws {
        let s = try pSetup()
        let catalogURL = s.folder.appendingPathComponent("catalog.json")
        let before = try Data(contentsOf: catalogURL)
        var forged = Proposal.make(title: "Invented card", actor: clerk, ops: [], now: pNow)
        forged.raw.set("id", .str("../../catalog"))
        #expect(throws: (any Error).self) { try ProposalStore.save(forged, in: s.folder) }
        #expect(throws: (any Error).self) { try ProposalStore.load("../../catalog", in: s.folder, expectedDigest: nil) }
        #expect(try Data(contentsOf: catalogURL) == before)

        // A file whose name and inner id disagree is neither listed nor loaded, so nothing rewrites it by that id.
        let dir = try ProposalStore.checkedDir(s.folder, create: true)
        let name = UUIDv7.make(now: pNow)
        let bytes = Data(JSONWriter.pretty(.object(forged.raw)).utf8)
        try bytes.write(to: dir.appendingPathComponent("\(name).json"))
        try bytes.write(to: dir.appendingPathComponent("notes.json"))
        #expect(!ProposalStore.list(in: s.folder).contains { $0.0.id == "../../catalog" || $0.0.id == name })
        #expect(throws: (any Error).self) { try ProposalStore.load(name, in: s.folder, expectedDigest: nil) }
    }

    // MARK: - 3. The offload's last check and removal hold the binder lock

    @Test func offloadRemovesTheFolderUnderTheBinderLock() throws {
        let e = try BugbotBackupTests().env()
        let locked = BugbotBackupTests.Switch(false)
        let trash = e.trash
        let b = Backup(support: e.support, key: "TEST-KEY-AAAAA-BBBBB", removeFolder: { url in
            // A writer arriving now finds the binder locked, so no approval can slip in before the folder goes.
            locked.on = (try? TekaStore(folder: url).withLock(timeout: 0) {}) == nil
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }, hubSpool: e.spool, uploadCheck: { _ in .notInICloud })
        let id = try Backup.backupID(e.folder)
        var job = Backup.InProgress(path: e.folder.standardizedFileURL.path, stage: "leaving")
        job.snapshot = "invented-snapshot"
        job.manifestSHA = Backup.digest(Backup.manifest(e.folder))
        var st = Backup.State()
        st.offloads[id] = job
        st.offloaded = [Backup.Offloaded(backupID: id, name: "estate-example", originalPath: job.path, snapshot: "invented-snapshot",
                                         secondSnapshot: nil, secondRepository: nil, bytes: 1, at: "2026-10-06T10:00:00Z", summary: "",
                                         documents: [], openItemsConfirmed: 0)]
        try b.save(st)
        guard case .done = try b.continueOffload(id, now: pNow) else { Issue.record("expected the offload to finish"); return }
        #expect(locked.on)
        #expect(!FileManager.default.fileExists(atPath: e.folder.path))
    }

    // MARK: - 4. A reading whose card was rejected is not readable by its id

    @Test func aRejectedDocumentCannotBeReadThroughARememberedID() throws {
        let m = BugbotMCPTests()
        let s = try m.setup(documents: true)
        let set = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([
            ("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("set_disclosure")),
            ("args", .obj([("disclosure", .str("full"))]))])), now: pNow, today: today)).value
        #expect(set["ok"] == .bool(true), "\(set)")
        let card = Proposal.make(title: "File the invented notice", actor: clerk, ops: [], now: pNow)
        try ProposalStore.save(card, in: s.folder)
        let store = IntakeReadings(support: s.commands.support)
        var e = IntakeReadings.Entry(id: "reading-astra", binder: s.folder.standardizedFileURL.path, name: "notice.txt",
                                     sha256: String(repeating: "0", count: 64), card: card.id,
                                     reading: IntakeReading(kind: "text", textFrom: "parsed", text: "An invented notice.", channel: "other"), now: pNow)
        e.escalation = "waiting"
        store.save(e)
        let args = JSONValue.obj([("binder", .str("estate-example")), ("reading_id", .str("reading-astra"))])
        #expect(try m.tool(s.server, "read_document", args)["isError"] == .bool(false))

        try TekaStore(folder: s.folder).reject(card, now: pNow)
        #expect(try m.tool(s.server, "read_document", args)["isError"] == .bool(true))
        #expect(try m.tool(s.server, "finish_reading", args)["isError"] == .bool(true))
        let proposed = try m.tool(s.server, "propose_ops", .obj([("binder", .str("estate-example")), ("title", .str("Invented card")),
                                                                 ("reading_id", .str("reading-astra")), ("ops", .array([m.addItem(1)]))]))
        #expect(proposed["isError"] == .bool(true))
        #expect(store.load("reading-astra")?.escalation == "waiting")
    }

    // MARK: - 5. A digest record that cannot be read is never saved over

    @Test func anUnreadableDigestRecordIsLeftAsItIs() throws {
        let s = try pSetup()
        let first = Proposal.make(title: "Invented card", actor: clerk, ops: [], now: pNow)
        try ProposalStore.save(first, in: s.folder)
        try s.commands.trustProposals([first.id], in: s.folder)
        try garbage.write(to: s.commands.digestsURL)

        let second = Proposal.make(title: "Another invented card", actor: clerk, ops: [], now: pNow)
        try ProposalStore.save(second, in: s.folder)
        #expect(throws: (any Error).self) { try s.commands.trustProposals([second.id], in: s.folder) }
        #expect(try call(s, [("command", .str("proposals")), ("binder", .string(s.folder.path))])["ok"] == .bool(false))
        #expect(try Data(contentsOf: s.commands.digestsURL) == garbage)
        // Only a missing record is an empty one.
        try FileManager.default.removeItem(at: s.commands.digestsURL)
        #expect(try s.commands.loadDigests().isEmpty)
    }

    // MARK: - 6. An intake cursor that cannot be read is reported and kept

    @Test func anUnreadableIntakeCursorIsReportedAndKept() throws {
        let s = try pSetup()
        let watcher = IntakeWatcher(support: s.support)
        let intake = s.folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("An invented letter.".utf8).write(to: intake.appendingPathComponent("letter.txt"))
        try AtomicFile.makePrivateFolder(watcher.stateURL.deletingLastPathComponent())
        try garbage.write(to: watcher.stateURL)

        let r = watcher.scan(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(r.cursorUnreadable && r.carded == 0 && r.waiting == 0)
        #expect(watcher.prepare(binders: pRows(s), deviceID: "dev", reader: .inProcess).readings.isEmpty)
        #expect(try Data(contentsOf: watcher.stateURL) == garbage)
        try FileManager.default.removeItem(at: watcher.stateURL)
        #expect(!watcher.scan(binders: pRows(s), commands: s.commands, now: pNow).cursorUnreadable)
    }

    // MARK: - 9. A missing document reader holds the file

    @Test func aMissingReaderHoldsTheFileAndInProcessReadingIsExplicit() throws {
        let s = try pSetup()
        let watcher = IntakeWatcher(support: s.support)
        let intake = s.folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("An invented letter about the levy.".utf8).write(to: intake.appendingPathComponent("letter.txt"))
        #expect(throws: ExtractHelper.Failure.self) { try ExtractHelper.run(Data("x".utf8), name: "x.txt", reader: .missing) }
        let reading = IntakeReading.read(intake.appendingPathComponent("letter.txt"), channel: "other", reader: .missing)
        #expect(reading.held?.contains("missing") == true && reading.text.isEmpty)

        _ = watcher.scan(binders: pRows(s), commands: s.commands, now: pNow, requireReading: true)
        let prepared = watcher.prepare(binders: pRows(s), deviceID: "dev", reader: .missing)
        let r = watcher.scan(binders: pRows(s), commands: s.commands, now: pNow, prepared: prepared, requireReading: true)
        #expect(r.carded == 1 && r.held == 1)
        let card = try #require(pOpen(s).first)
        #expect(card.title.hasPrefix("Held:"))
        #expect(card.cardNotes.contains { $0.contains("reader") && $0.contains("missing") })
        // Reading in this process happens only when asked for by name.
        #expect(try ExtractHelper.run(Data("An invented note.".utf8), name: "note.txt", reader: .inProcess).text.contains("invented"))
    }

    // MARK: - 10. MCP logs name only known methods

    @Test func mcpLogsCarryOnlyKnownMethodNames() {
        #expect(MCPServer.loggedMethod(#"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#) == "tools/call")
        #expect(MCPServer.loggedMethod(#"{"jsonrpc":"2.0","id":1,"method":"x\nmcp client=other auth=ok invented text"}"#) == "unknown_method")
        #expect(MCPServer.loggedMethod(#"{"jsonrpc":"2.0","id":1,"method":7}"#) == "unknown_method")
        #expect(MCPServer.loggedMethod("not json") == "unknown_method")
    }
}
