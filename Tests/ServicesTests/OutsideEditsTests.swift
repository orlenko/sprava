import BinderFormat
import BinderStore
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Outside edits reach the op log when a background reader sees them (architecture 4.5), and the cards Sprava
/// wrote while its record of trusted cards could not be written are trusted later, by the digest it wrote and
/// never by what the file holds by then (architecture 4.6). Invented data only.
@Suite(.serialized) struct OutsideEditsTests: BinderCommandFixture {
    @Test func aTemporarilyUnreadableRecoveryCardKeepsItsRetryEvidence() throws {
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let card = Proposal.make(title: "Invented recovery", actor: user, ops: [body("drop", .obj([
            ("id", .str("item-0006")), ("closed_at", .str("2026-10-06T08:00:00Z")), ("source", .str("user"))]))], now: now)
        try ProposalStore.save(card, in: folder)
        let digests = c.support.appendingPathComponent("runtime/proposal-digests.json")
        let recorded = try Data(contentsOf: digests)
        try Data("not json".utf8).write(to: digests)
        let backlog = TrustBacklog(support: c.support)
        #expect(throws: (any Error).self) { try backlog.trust([card.id], in: folder, commands: c) }
        #expect(backlog.count == 1)
        let pending = try Data(contentsOf: backlog.url)
        let file = folder.appendingPathComponent(".sprava/proposals/\(card.id).json")
        #expect(chmod(file.path, 0o000) == 0)
        try recorded.write(to: digests)
        let afterRestart = TrustBacklog(support: c.support)
        #expect(throws: (any Error).self) { try afterRestart.retry(commands: c) }
        #expect(afterRestart.count == 1)
        #expect(try Data(contentsOf: backlog.url) == pending)
        #expect(chmod(file.path, 0o600) == 0)
        try TrustBacklog(support: c.support).retry(commands: c)
        #expect(c.isTrusted(card.id, in: folder))
        #expect(!FileManager.default.fileExists(atPath: backlog.url.path))
    }

    @Test func aHandEditIsRecordedWithoutAWrite() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: now)
        let url = folder.appendingPathComponent("catalog.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: "\"estate-example-2026-007\"", with: "\"estate-example-2026-007\", \"note\": \"edited by hand\"")
            .write(to: url, atomically: true, encoding: .utf8)
        let at = Date()
        let rows = Shelf.rows(registry: nil, picked: [folder])
        #expect(OutsideEdits.settle(rows, deviceID: "t", now: at).failed.isEmpty)
        #expect(try TekaStore(folder: folder).readOpLog().ops.last?["op"] == .str("external_edit"))
        let day = CalendarDate.today(now: at)
        #expect(Measures(support: FileManager.default.temporaryDirectory.appendingPathComponent("sprava-measures-\(UUID().uuidString)")).compute(rows: rows, from: day, to: day, now: at).externalEdits.count == 1)
        // Settling again finds nothing new.
        _ = OutsideEdits.settle(rows, deviceID: "t", now: at)
        #expect(try TekaStore(folder: folder).readOpLog().ops.filter { $0["op"] == .str("external_edit") }.count == 1)
    }

    @Test func aFailedTrustIsReportedAndRetriedByTheDigestWritten() throws {
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let catalogURL = folder.appendingPathComponent("catalog.json")
        let before = try Data(contentsOf: catalogURL)
        let card = Proposal.make(title: "Drop", actor: user, ops: [body("drop", .obj([
            ("id", .str("item-0006")), ("closed_at", .str("2026-10-06T08:00:00Z")), ("source", .str("user"))]))], now: now)
        try ProposalStore.save(card, in: folder)
        try TekaStore(folder: folder).approve(card, now: now)
        try before.write(to: catalogURL)   // another program puts the old copy back

        // Sprava's record of the cards cannot be read.
        let digests = c.support.appendingPathComponent("runtime/proposal-digests.json")
        let recorded = try Data(contentsOf: digests)
        try Data("not json".utf8).write(to: digests)
        let rows = Shelf.rows(registry: nil, picked: [folder])
        let listed = Set(ProposalStore.list(in: folder).map(\.0.id))
        let backlog = TrustBacklog(support: c.support)
        let first = OutsideEdits.settleAndTrust(rows, commands: c, backlog: backlog, now: now) { $0() }
        #expect(first.cards == 1 && first.untrusted == 1 && first.unsettled == 0)
        let id = try #require(ProposalStore.list(in: folder).map(\.0.id).first { !listed.contains($0) })
        #expect(FileManager.default.fileExists(atPath: backlog.url.path))

        // Still unreadable: the next pass offers the same card again (made anew from the log, never a second card)
        // and still fails to trust it.
        let second = OutsideEdits.settleAndTrust(rows, commands: c, backlog: backlog, now: now) { $0() }
        #expect(second.untrusted == 1)
        #expect(ProposalStore.list(in: folder).filter { $0.0.state == "proposed" }.map(\.0.id) == [id])

        // Repaired, but another program changed the card in between: the pass makes it again from the log, writing
        // Sprava's own bytes over the change, and trusts what it wrote, never the changed bytes.
        try recorded.write(to: digests)
        let file = folder.appendingPathComponent(".sprava/proposals/\(id).json")
        let written = try Data(contentsOf: file)
        try (written + Data("\n".utf8)).write(to: file)
        let third = OutsideEdits.settleAndTrust(rows, commands: c, backlog: backlog, now: now) { $0() }
        #expect(third.untrusted == 0)
        #expect(!FileManager.default.fileExists(atPath: backlog.url.path))
        #expect(try Data(contentsOf: file) == written)
        #expect(c.isTrusted(id, in: folder))
        try (written + Data("\n".utf8)).write(to: file)
        #expect(!c.isTrusted(id, in: folder))
        try written.write(to: file)

        // A fresh backlog (a restart) also finds what the file kept.
        try Data("not json".utf8).write(to: digests)
        #expect(throws: (any Error).self) { try TrustBacklog(support: c.support).trust([id], in: folder, commands: c) }
        try recorded.write(to: digests)
        try TrustBacklog(support: c.support).retry(commands: c)
        #expect(c.isTrusted(id, in: folder))
    }

    @Test func aBacklogNeverTrustsACardThisProcessDidNotWrite() throws {
        let c = commands()
        let (folder, _) = try readyBinder(c)
        // A card another program dropped into the binder.
        let card = Proposal.make(title: "Dropped in", actor: user, ops: [body("drop", .obj([
            ("id", .str("item-0006")), ("closed_at", .str("2026-10-06T08:00:00Z")), ("source", .str("user"))]))], now: now)
        let dir = folder.appendingPathComponent(".sprava/proposals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(JSONWriter.pretty(.object(card.raw)).utf8).write(to: dir.appendingPathComponent("\(card.id).json"))
        let backlog = TrustBacklog(support: c.support)
        #expect(throws: TrustBacklog.NotWrittenHere.self) { try backlog.trust([card.id], in: folder, commands: c) }
        #expect(!c.isTrusted(card.id, in: folder))
        #expect(backlog.count == 0)
        #expect(!FileManager.default.fileExists(atPath: backlog.url.path))
    }
}
