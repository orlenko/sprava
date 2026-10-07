import Foundation
import Testing
@testable import SpravaCore

@Suite(.serialized) struct AdoptionTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    @Test func adoptingALiveLifeprojBinderEndsReadyAfterTwoApprovals() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "test-device", today: today, now: now)

        // One lossless fix: the waiting item gets a derived follow-up date, today (its due date has passed).
        #expect(result.mechanical.count == 1)
        let item = Teka.read(folder).items.first { $0.idText == "rental-elm-street-2026-004" }
        #expect(item?.followUpAt?.description == "2026-10-07")
        #expect(item?.derived == ["follow_up_at"])

        // Two proposals: close the done item, then stamp.
        #expect(result.proposals.map(\.title) == ["Close 1 item(s) already marked done", "Stamp this binder as binder v0"])
        let store = TekaStore(folder: folder)
        #expect(Teka.read(folder).state == .needsMigration)
        // Stamping first is refused: the done item would break v0.
        #expect(throws: TransactionGuard.Rejection.self) { try store.approve(result.proposals[1], now: now) }
        try store.approve(result.proposals[0], now: now)
        try store.approve(try ProposalStore.load(result.proposals[1].id, in: folder, expectedDigest: nil), now: now)
        let teka = Teka.read(folder)
        #expect(teka.level == .tekaV0)
        #expect(teka.state == .ready, "\(teka.reasons) \(teka.findings)")
        #expect(teka.catalog?["meta"]?["disclosure"] == .str("none"))

        // History: the snapshot, the fix, the closure, the stamp; it replays to the catalog on disk.
        let ops = try store.readOpLog().ops
        #expect(ops.map { $0["op"]?.stringValue ?? "" } == ["import_snapshot", "update_item", "complete", "migrate"])
        #expect(ops[2]["approved_by"] == .str("user") && ops[2]["proposal"] == .string(result.proposals[0].id))
        let replayed = try Replay.run(ops)
        #expect(.object(replayed) == .object(teka.catalog!))
        // The done item's closure keeps its fields in `final`.
        let closure = teka.catalog?["processing_log"]?.arrayValue?.last { $0["id"] == .str("item-0005") }
        #expect(closure?["final"]?["due"] == .str("2026-09-15"))
        // The proposals record their outcome.
        let states = ProposalStore.list(in: folder).map { $0.0.state }
        #expect(states == ["applied", "applied"])
    }

    @Test func surveyHoldsCountsNeverText() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        let survey = Adoption.survey(folder, inRegistry: true)
        let text = JSONWriter.compact(.object(survey))
        #expect(!text.contains("insurance") && !text.contains("furnace") && !text.contains("Звіт"))
        #expect(survey["done_in_open_items"] == .int(1))
        #expect(survey["foreign_absolute_paths"] == .int(1))
        #expect(survey["lifeproj_can_reach"] == .bool(true))
        #expect(survey["ids"] == .str("opaque"))
    }

    @Test func aRejectedProposalChangesNothing() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now)
        let before = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        try TekaStore(folder: folder).reject(result.proposals[0], reason: "not yet", now: now)
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == before)
        #expect(try ProposalStore.load(result.proposals[0].id, in: folder, expectedDigest: nil).state == "rejected")
    }

    @Test func aRewrittenProposalFileIsCaught() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now)
        let (_, digest) = try #require(ProposalStore.list(in: folder).first { $0.0.id == result.proposals[0].id })
        var raw = result.proposals[0].raw
        raw.set("title", .str("something else"))
        try ProposalStore.save(Proposal(raw: raw), in: folder)
        #expect(throws: ProposalStore.Tampered.self) {
            try ProposalStore.load(result.proposals[0].id, in: folder, expectedDigest: digest)
        }
    }
}
