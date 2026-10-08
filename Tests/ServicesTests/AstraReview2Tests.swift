import Backup
import BinderFormat
import BinderStore
import Brains
import Capture
import Darwin
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the second adversarial review of increment 1 (hub titles under the privacy ratchet, the backup
/// queue, intake cards whose digest was not kept, concurrent Shelf changes, revocation on the command queue).
/// Invented data only.
@Suite(.serialized) struct AstraReview2Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    let meta = #""_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}"#

    func temp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra2-\(label)-\(UUID().uuidString)")
    }

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    func proposals(_ c: Commands, _ folder: URL) throws -> [JSONValue] {
        try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? []
    }

    // MARK: - 1. A hub title Sprava applied stays until the person allows an outside change

    /// A lifeproj v2 binder adopted and approved to ready, publishing at full, with a spool next to it.
    func readyBinder(_ c: Commands) throws -> (URL, URL) {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path)), ("in_registry", .bool(true))])
        for card in try proposals(c, folder) {
            _ = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        }
        let spool = folder.deletingLastPathComponent().appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (folder, spool)
    }

    /// Changes one item in catalog.json the way another program would: no lock, no op.
    func outsideEdit(_ folder: URL, item id: String, _ change: (inout JSONObject) -> Void) throws {
        let url = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
        catalog.set("open_items", .array((catalog["open_items"]?.arrayValue ?? []).map { v in
            guard v["id"] == .string(id), case .object(var o) = v else { return v }
            change(&o)
            return .object(o)
        }))
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
    }

    func hubTitles(_ folder: URL, _ spool: URL) throws -> [String] {
        _ = try HubLane.publish(folder, root: spool, now: now)
        let slice = try JSONParser.parse(try Data(contentsOf: spool.appendingPathComponent("inbox/rental-elm-street.agenda.json"))).value
        return slice["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
    }

    func approvePrivacyCard(_ c: Commands, _ folder: URL, line: String) throws {
        let card = try #require(try proposals(c, folder).first { card in
            card["state"] == .str("proposed") && card["lines"]?.arrayValue?.contains { $0.stringValue?.contains(line) == true } == true
        })
        #expect(card["verified"] == .bool(true))
        #expect(card["lines"]?.arrayValue?.contains { $0.stringValue?.contains("privacy change") == true } == true)
        let r = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        #expect(r["ok"] == .bool(true), "\(r)")
    }

    @Test func aHubTitleRemovedOrChangedOutsideStaysUntilThePersonAllowsIt() throws {
        let c = Commands(support: temp("support"), deviceID: "dev")
        let (folder, spool) = try readyBinder(c)
        let natural = "Звіт для бухгалтера"
        let r = try call(c, [("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("update_item")),
                             ("args", .obj([("id", .str("item-0006")), ("set", .obj([("slice_title", .str("Invented paperwork"))]))]))])
        #expect(r["ok"] == .bool(true), "\(r)")
        #expect(try hubTitles(folder, spool).contains("Invented paperwork"))

        // Removed outside: the hub keeps the confirmed title, never the natural one.
        try outsideEdit(folder, item: "item-0006") { $0.remove("slice_title") }
        var titles = try hubTitles(folder, spool)
        #expect(titles.contains("Invented paperwork") && !titles.contains(natural), "\(titles)")
        // Changed outside: the same.
        try outsideEdit(folder, item: "item-0006") { $0.set("slice_title", .str("Invented changed title")) }
        titles = try hubTitles(folder, spool)
        #expect(titles.contains("Invented paperwork") && !titles.contains("Invented changed title"), "\(titles)")

        // The person allows the change on a privacy card; then the hub follows it.
        try approvePrivacyCard(c, folder, line: "slice_title")
        titles = try hubTitles(folder, spool)
        #expect(titles.contains("Invented changed title"), "\(titles)")

        // A removal allowed the same way lets the natural title through, and only then.
        try outsideEdit(folder, item: "item-0006") { $0.remove("slice_title") }
        #expect(!(try hubTitles(folder, spool)).contains(natural))
        try approvePrivacyCard(c, folder, line: "remove slice_title")
        #expect(try hubTitles(folder, spool).contains(natural))
        // Nothing is left waiting once the found title is the confirmed one.
        #expect(try PrivacyRatchet.ensureCard(folder: folder, client: "t", now: now) == nil)
    }

    // MARK: - 3. An intake card whose digest was not kept is never left behind

    struct Intake {
        let support: URL
        let commands: Commands
        let folder: URL
        let watcher: IntakeWatcher
        var rows: [ShelfRow] { [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))] }
        var cards: [Proposal] {
            ProposalStore.list(in: folder).map(\.0).filter { $0.state == "proposed" && $0.raw["provenance"]?["intake"] != nil }
        }
    }

    func intake() throws -> Intake {
        let support = temp("support")
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        let r = try call(commands, [("command", .str("adopt")), ("binder", .string(folder.path))])
        #expect(r["ok"] == .bool(true), "\(r)")
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: now) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        try Data("INVENTED NOTICE. The invented levy of $120.00 is due November 1, 2026.".utf8)
            .write(to: folder.appendingPathComponent("intake/levy.txt"))
        return Intake(support: support, commands: commands, folder: folder, watcher: IntakeWatcher(support: support))
    }

    /// A scan with a reading before it, as the runtime does once a file held still.
    @discardableResult
    func scan(_ s: Intake) -> IntakeWatcher.ScanResult {
        let prepared = s.watcher.prepare(binders: s.rows, deviceID: "dev", reader: .inProcess)
        return s.watcher.scan(binders: s.rows, commands: s.commands, now: now, prepared: prepared, requireReading: true)
    }

    func clearCursorCard(_ s: Intake) throws {
        var state = try s.watcher.load()
        state[s.folder.standardizedFileURL.path]?["levy.txt"]?.card = nil
        try s.watcher.save(state)
    }

    @Test func aFailedTrustWriteLeavesTheFileUncardedForTheNextScan() throws {
        let s = try intake()
        scan(s)   // first sight: waits to hold still
        let garbage = Data("{\"broken".utf8)
        try AtomicFile.makePrivateFolder(s.commands.digestsURL.deletingLastPathComponent())
        try garbage.write(to: s.commands.digestsURL)
        #expect(scan(s).carded == 0)
        #expect(s.cards.isEmpty)
        #expect(try s.watcher.load()[s.folder.standardizedFileURL.path]?["levy.txt"]?.card == nil)
        #expect(try Data(contentsOf: s.commands.digestsURL) == garbage)

        // Storage recovers: the next scan cards the file, trusted, with its reading.
        try FileManager.default.removeItem(at: s.commands.digestsURL)
        #expect(scan(s).carded == 1)
        let card = try #require(s.cards.first)
        #expect(s.commands.isTrusted(card.id, in: s.folder))
        #expect(IntakeReadings(support: s.support).forCard(card.id) != nil)
    }

    @Test func aWaitingCardIsTakenOverOnlyWhenTrustedAndWithItsReading() throws {
        let s = try intake()
        scan(s)
        scan(s)
        let first = try #require(s.cards.first)
        let readings = IntakeReadings(support: s.support)

        // The cursor lost its card and the reading is gone: the trusted card is taken over, its reading made again.
        try clearCursorCard(s)
        try FileManager.default.removeItem(at: readings.url(try #require(readings.forCard(first.id)).id))
        scan(s)
        #expect(s.cards.map(\.id) == [first.id])
        #expect(try s.watcher.load()[s.folder.standardizedFileURL.path]?["levy.txt"]?.card == first.id)
        #expect(readings.forCard(first.id) != nil)

        // A card left without its digest (as an earlier failure could leave it) is withdrawn, and the file carded again.
        try clearCursorCard(s)
        try Data("{}".utf8).write(to: s.commands.digestsURL)
        scan(s)
        let second = try #require(s.cards.first)
        #expect(s.cards.count == 1 && second.id != first.id)
        #expect(s.commands.isTrusted(second.id, in: s.folder))
        #expect(ProposalStore.list(in: s.folder).first { $0.0.id == first.id }?.0.state == "rejected")
    }

    // MARK: - 4. An unreadable request queue is reported and never overwritten

    @Test func anUnreadableRequestQueueIsNeverOverwritten() throws {
        let support = temp("support")
        let c = Commands(support: support, deviceID: "dev")
        let requests = BackupRequests(support: support)
        #expect(try requests.all().isEmpty)   // a missing queue is an empty one
        try AtomicFile.makePrivateFolder(requests.url.deletingLastPathComponent())
        let garbage = Data("[{\"id\": \"invented\", broken".utf8)
        try garbage.write(to: requests.url)

        #expect(throws: (any Error).self) { try requests.all() }
        #expect(throws: (any Error).self) { try requests.next() }
        #expect(throws: (any Error).self) { try requests.enqueue(.init(id: "x", kind: "drill", binder: "/Invented/x", at: ISOTime.string(now))) }
        #expect(throws: (any Error).self) { try requests.recoverInterrupted() }
        requests.update("invented") { $0.state = "failed" }
        let r = try call(c, [("command", .str("backup_request")), ("kind", .str("restore")), ("backup_id", .str("invented-id"))])
        #expect(r["ok"] == .bool(false), "\(r)")
        let status = try call(c, [("command", .str("backup_status"))])
        #expect(status["ok"] == .bool(false), "\(status)")
        #expect(try Data(contentsOf: requests.url) == garbage)
    }

    // MARK: - 6. A revocation queued ahead of a brain's call is seen before the call runs

    @Test func aRevocationQueuedAheadOfACallStopsIt() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        let support = temp("sock")
        let c = Commands(support: support, deviceID: "dev")
        let token = try #require(try call(c, [("command", .str("register_client")), ("client_id", .str("brain-7")),
                                              ("binders", .obj([(folder.standardizedFileURL.path, .str("propose"))]))])["token"]?.stringValue)
        let queue = DispatchQueue(label: "test.mcp.commands")
        let listener = MCPListener(support: support, commands: c, queue: queue,
                                   shelf: { Shelf.rows(registry: nil, picked: [folder]) }, log: { _ in })
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let server = fds[1]
        Thread { listener.serve(server) }.start()
        let client = fds[0]
        defer { close(client) }
        setTimeout(client, seconds: 5)
        let reader = LineReader(fd: client)
        #expect(writeLine(client, JSONWriter.compact(.obj([("sprava_auth", .obj([("client_id", .str("brain-7")), ("token", .string(token))]))]))))
        guard case .line(let auth) = reader.next(limit: 4096) else { Issue.record("no reply to the preamble"); return }
        #expect(auth.contains("\"ok\":true"))

        // The command queue is busy; the call arrives and waits behind it, then the revocation lands first.
        let busy = DispatchSemaphore(value: 0)
        queue.async { busy.wait() }
        #expect(writeLine(client, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{\#(meta),"name":"list_binders","arguments":{}}}"#))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(try call(c, [("command", .str("revoke_client")), ("client_id", .str("brain-7"))])["ok"] == .bool(true))
        busy.signal()
        guard case .end = reader.next(limit: MCPListener.lineLimit) else { Issue.record("the revoked client's call ran"); return }
    }
}
