import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// An intake card is left behind only when it is trusted and has its reading: a card whose digest could not be
/// recorded is not made, and a waiting card is taken over only when trusted. Invented data only.
@Suite(.serialized) struct IntakeTrustTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

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
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-intake-trust-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        try adoptAsCommand(folder, commands: commands, now: now, today: today)
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
}
