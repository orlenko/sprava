import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Darwin
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from Codex Bugbot's review of the final capture layer (PR #13). Invented data only.
@Suite(.serialized) struct BugbotFinalTests {
    let adapter = "11111111-2222-4333-8444-5555555555fc"

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return s
    }

    @discardableResult
    func sweep(_ s: PSetup, _ rows: [ShelfRow]? = nil) -> CaptureInbox.SweepResult {
        s.inbox.sweep(binders: rows ?? pRows(s), commands: s.commands, now: pNow)
    }

    func from(_ p: Proposal, _ id: String) -> Bool { p.raw["provenance"]?["events"] == .array([.string(id)]) }

    func age(_ url: URL, hours: Double) {
        let then = Date().addingTimeInterval(-hours * 3600).timeIntervalSince1970
        var times = [timeval(tv_sec: Int(then), tv_usec: 0), timeval(tv_sec: Int(then), tv_usec: 0)]
        _ = utimes(url.path, &times)
    }

    /// An event written by hand into `device`'s folder with the id and stamp given.
    func event(_ s: PSetup, device: String, id: String, ref: String, revision: String, text: String, wall: Int, counter: Int) throws {
        var o = JSONObject()
        o.set("format", .str("sprava-capture-event"))
        o.set("format_version", .str("0"))
        o.set("id", .string(id))
        o.set("hlc", .obj([("wall_ms", .int(wall)), ("counter", .int(counter)), ("node", .string(device.replacingOccurrences(of: "-", with: "")))]))
        o.set("device", .obj([("id", .string(device))]))
        o.set("source", .obj([("app", .str("adapter")), ("kind", .str("dictation")), ("ref", .string(ref)), ("revision", .string(revision))]))
        o.set("captured_at", .str("2026-10-06T09:00:00-04:00"))
        o.set("locale", .str("en-CA"))
        o.set("text", .string(text))
        o.set("sensitivity", .str("unmarked"))
        let folder = s.producer.root.appendingPathComponent(device)
        try AtomicFile.makePrivateFolder(folder)
        try CaptureProducer.publish(Data(JSONWriter.pretty(.object(o)).utf8), as: folder.appendingPathComponent("\(id).json"))
    }

    // MARK: - MUST-FIX

    @Test func aDamagedPathInTheCursorSetsTheClerksWorkAsideInsteadOfTrapping() throws {
        let s = try setup()
        let id = try pEvent(s, device: adapter, app: "adapter", ref: "P1", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        var state = try s.inbox.readState()
        state.paths?[id] = ""
        try s.inbox.save(state)
        #expect(s.inbox.nextForClerk() == nil)
        #expect(try s.inbox.readState().clerk?[id] == "kept")
    }

    @Test func aPrivacyDebtStaysWhileTheRecordOfWrittenCardsCannotBeRead() throws {
        let s = try setup()
        // The chain's item is filed in the binder, which is then taken off the shelf (still known from the record).
        let id = try pEvent(s, device: adapter, app: "adapter", ref: "P2", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        try s.inbox.file(try #require(s.inbox.unfiled().first { from($0, id) }).id, into: s.folder, commands: s.commands)
        _ = try TekaStore(folder: s.folder).approve(try #require(pOpen(s).first { from($0, id) }), now: pNow)
        let digests = s.commands.digestsURL
        chmod(digests.path, 0o000)
        defer { chmod(digests.path, 0o600) }
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "P2", revision: "rev1", text: "Call the invented roofer") {
            $0.set("sensitivity", .str("private"))
        }
        sweep(s, [])
        #expect(try s.inbox.readState().debts?.isEmpty == false, "a binder only the record names may still hold the item")
        chmod(digests.path, 0o600)
        sweep(s, [])
        #expect(try s.inbox.readState().debts?.isEmpty != false)
        #expect(pOpen(s).contains { CaptureInbox.onlyRedacts($0) }, "the binder off the shelf gets its redaction card")
    }

    @Test func anIntakeFolderOutOfReachIsNotTakenForAnEmptyOne() throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        try t.write(s, "levy.txt", IntakeReadingTests.notice)
        _ = t.card(s)
        let card = try #require(t.open(s).first)
        // intake/ becomes a link (not a plain folder of this user): it is out of reach, not empty.
        let intake = s.folder.appendingPathComponent("intake")
        let moved = s.folder.appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: intake, to: moved)
        try FileManager.default.createSymbolicLink(at: intake, withDestinationURL: moved)
        let result = s.watcher.scan(binders: t.rows(s), commands: s.commands, now: t.now)
        #expect(result.unreadableFolders == 1)
        #expect(t.open(s).contains { $0.id == card.id }, "its card stays")
    }

    @Test func anIntakeReplacementThatCannotBeTrustedGoesAndTheReadingIsTriedAgain() async throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        try t.write(s, "levy.txt", IntakeReadingTests.notice)
        _ = t.card(s)
        let tier0 = try #require(t.open(s).first)
        let model = ScriptedModel(extractions: [.obj([("items", .array([
            item("The special levy of $450.00 is due November 1, 2026", "Pay the special levy", "pay", when: "November 1, 2026"),
        ]))])])
        model.document = .obj([("class", .str("action")), ("title", .str("Notice of special levy")), ("date_text", .str("September 30, 2026")),
                               ("summary", .str("An invented notice.")), ("reply_needed", .bool(false))])
        let entry = try #require(s.watcher.nextForReading())
        let binder = FilingBinder(name: Teka.read(s.folder).name, description: "", folder: s.folder,
                                  openItems: FilingBinder.candidates(catalog: Teka.read(s.folder).catalog))
        let doc = await Clerk(model: model).readDocument(entry.reading, name: entry.name, binder: binder, now: t.now)
        // The record of written cards can be read but not written: the replacement is saved, never trusted.
        let runtime = s.commands.digestsURL.deletingLastPathComponent()
        chmod(runtime.path, 0o500)
        defer { chmod(runtime.path, 0o700) }
        let outcome = s.watcher.commitReading(entry, doc, commands: s.commands, now: t.now)
        chmod(runtime.path, 0o700)
        #expect(!outcome.replaced)
        #expect(t.open(s).map(\.id) == [tier0.id], "no untrusted card waits beside the code-built one")
        #expect(IntakeReadings(support: s.support).load(entry.id)?.state == "pending", "the reading is tried again")
    }

    @Test func aFileThatNeverParsesIsQuarantinedAfterTheGracePeriod() throws {
        let s = try setup()
        let folder = s.producer.root.appendingPathComponent(adapter)
        try AtomicFile.makePrivateFolder(folder)
        let file = folder.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        try Data("{\"format\": \"sprava-capture-ev".utf8).write(to: file)
        #expect(sweep(s).pending == 1, "still arriving")
        age(file, hours: 2)
        #expect(sweep(s).quarantined == 1)
        #expect(s.inbox.health().quarantined == 1)
    }

    @Test func aStaleTemporaryOfAnEventNoLongerBlocksItsPublication() throws {
        let s = try setup()
        let folder = s.producer.root.appendingPathComponent(adapter)
        try AtomicFile.makePrivateFolder(folder)
        let url = folder.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        let temp = folder.appendingPathComponent("." + url.lastPathComponent + ".tmp")
        try Data("partial".utf8).write(to: temp)
        // A temporary younger than an hour may still be written by another process: it is left alone.
        #expect(throws: (any Error).self) { try CaptureProducer.publish(Data("{}".utf8), as: url) }
        age(temp, hours: 2)
        try CaptureProducer.publish(Data("{}".utf8), as: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func equalStampsFromTwoDevicesAreOrderedByNodeNotId() throws {
        let s = try setup()
        let low = "11111111-2222-4333-8444-5555555555fc"   // `adapter`, the smaller node
        let high = "ffffffff-2222-4333-8444-5555555555fc"
        try s.inbox.registerProducer(folder: high, app: "adapter")
        let first = "ffffffff-0000-4000-8000-000000000001", second = "00000000-0000-4000-8000-000000000002"
        try event(s, device: low, id: first, ref: "N1", revision: "rev1", text: "Call the invented roofer", wall: 1_791_360_000_000, counter: 7)
        sweep(s)
        // The same stamp from the device whose node sorts higher, with an id that sorts lower: it is the later one.
        try event(s, device: high, id: second, ref: "N1", revision: "rev2", text: "Call the invented roofer\nPay the invented levy",
                  wall: 1_791_360_000_000, counter: 7)
        sweep(s)
        #expect(try s.inbox.readState().ingested[second] != "stale_revision")
        #expect((pOpen(s) + s.inbox.unfiled()).contains { from($0, second) })
    }

    // MARK: - Issues small enough to fix here

    @Test func anEventWithAnEmptyRefIsQuarantined() throws {
        let s = try setup()
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "", revision: "rev1", text: "Call the invented roofer")
        #expect(sweep(s).quarantined == 1)
    }

    @Test func aNoticeJournalThatCannotBeReadStopsTheSweep() throws {
        let s = try setup()
        try s.inbox.recordNotice(event: UUID().uuidString.lowercased(), digest: "sha256:00")
        chmod(s.inbox.noticesURL.path, 0o000)
        defer { chmod(s.inbox.noticesURL.path, 0o600) }
        #expect(sweep(s).unreadable != nil)
    }

    @Test func aDeviceFolderThatCannotBeListedIsCounted() throws {
        let s = try setup()
        let folder = s.producer.root.appendingPathComponent(adapter)
        try AtomicFile.makePrivateFolder(folder)
        chmod(folder.path, 0o300)
        defer { chmod(folder.path, 0o700) }
        #expect(sweep(s).refusedFolders == 1)
    }

    @Test func aQuarantineThatCannotBeKeptIsTriedAgain() throws {
        let s = try setup()
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "Q1", revision: "rev1", text: "Call the invented roofer") {
            $0.set("locale", .int(3))
        }
        try AtomicFile.makePrivateFolder(s.inbox.quarantineDir)
        chmod(s.inbox.quarantineDir.path, 0o500)
        defer { chmod(s.inbox.quarantineDir.path, 0o700) }
        sweep(s)
        #expect(s.inbox.health().quarantined == 0)
        chmod(s.inbox.quarantineDir.path, 0o700)
        sweep(s)
        #expect(s.inbox.health().quarantined == 1)
    }

    @Test func aNoteIsNotStampedWhenItsFolderCannotBeListed() throws {
        let s = try setup()
        _ = try s.producer.writeNote("Call the invented roofer", startedAt: pNow, savedAt: pNow, locale: "en-CA")
        let folder = s.producer.root.appendingPathComponent(pDevice)
        chmod(folder.path, 0o300)
        defer { chmod(folder.path, 0o700) }
        #expect(throws: (any Error).self) { _ = try s.producer.prepareNote("Pay the invented levy", startedAt: pNow, savedAt: pNow, locale: "en-CA") }
    }

    @Test func aCorrectionThePersonRejectedIsNotMadeAgainOnARetry() throws {
        let s = try setup()
        let id = try pEvent(s, device: adapter, app: "adapter", ref: "R1", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        try s.inbox.file(try #require(s.inbox.unfiled().first { from($0, id) }).id, into: s.folder, commands: s.commands)
        _ = try TekaStore(folder: s.folder).approve(try #require(pOpen(s).first { from($0, id) }), now: pNow)
        let revision = try pEvent(s, device: adapter, app: "adapter", ref: "R1", revision: "rev2", text: "Call the invented roofer Monday")
        // The correction card is made, but its stage cannot be saved: the event stays to be taken in again.
        CursorCrash.after(1, cursor: s.inbox.stateURL)
        sweep(s)
        CursorCrash.after(nil, cursor: s.inbox.stateURL)
        let card = try #require(pOpen(s).first { CaptureInbox.isCorrection($0, of: revision) })
        _ = try TekaStore(folder: s.folder).reject(card, now: pNow)
        sweep(s)
        #expect(!pOpen(s).contains { CaptureInbox.isCorrection($0, of: revision) }, "the person's rejection stands")
    }
}
