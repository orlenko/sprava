import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

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

    /// A lifeproj binder named `tax` holding `items`, at `schema_version`.
    func lifeproj(_ items: [String], schemaVersion: Int = 2) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-adopt-\(UUID().uuidString)/tax", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"meta":{"schema_version":\#(schemaVersion),"name":"tax"},"documents":[],"open_items":[\#(items.joined(separator: ","))],"processing_log":[]}"#.utf8)
            .write(to: folder.appendingPathComponent("catalog.json"))
        return folder
    }

    // Layer 5 review, finding 2: a follow-up date written after the survey is never overwritten by a mechanical fix.
    @Test func aMechanicalFixSeesAnEditMadeAfterTheSurvey() throws {
        let waiting = #"{"id":"w-1","title":"Invented wait","status":"waiting","priority":"normal","due":"2026-11-01","waiting_on":"an invented office"}"#
        let folder = try lifeproj([waiting])
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        // The person supplies the date in an editor between the survey and the fix.
        let url = folder.appendingPathComponent("catalog.json")
        let edited = waiting.replacingOccurrences(of: #""waiting_on""#, with: #""follow_up_at":"2026-10-30","waiting_on""#)
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: waiting, with: edited)
        #expect(text.contains("2026-10-30"))
        store.testHookBeforeLock = {
            try? Data(text.utf8).write(to: url)
            store.testHookBeforeLock = nil
        }
        let actor = JSONObject([(key: "kind", value: .str("import")), (key: "client", value: .str("t"))])
        let applied = try Adoption.applyMechanicalFixes(store: store, ids: [.str("w-1")], today: today, actor: actor, now: now)
        #expect(applied.isEmpty)
        let item = Teka.read(folder).items.first { $0.idText == "w-1" }
        #expect(item?.followUpAt?.description == "2026-10-30")
        #expect(item?.derived == nil || item?.derived == [])
        #expect(try store.readOpLog().ops.contains { $0["op"] == .str("external_edit") })
    }

    // Layer 5 review, finding 5: an item that passes lifeproj's rules but not v0's gets a repair card, so adoption
    // always has a way to the stamp.
    @Test func itemsThatBreakOnlyTheV0RulesGetRepairCards() throws {
        let redacted = #"{"id":"r-1","title":"Invented private matter","status":"open","priority":"normal","due":"2026-11-01","redact":true}"#
        let plain = #"{"id":"p-1","title":"Invented task","status":"open","priority":"normal","due":"2026-11-01"}"#
        let v2 = try lifeproj([redacted, plain])
        #expect(Teka.read(v2).findings.isEmpty)
        let result = try Adoption.adopt(v2, inRegistry: false, deviceID: "t", today: today, now: now)
        let repairs = result.proposals.filter { $0.raw["provenance"]?["repair"] != nil }
        #expect(repairs.count == 1)
        #expect(repairs.first?.raw["provenance"]?["repair"] == .array([.str("kind")]))
        #expect(repairs.first?.ops.first?["args"]?["id"] == .str("r-1"))
        #expect(!result.proposals.contains { $0.raw["provenance"]?["adoption"] == .str("stamp") })

        // A v1 catalog has no item rules of its own; an item without a priority still needs one for v0.
        let v1 = try lifeproj([#"{"id":"q-1","title":"Invented question","status":"open","due":"2026-11-01"}"#], schemaVersion: 1)
        let r1 = try Adoption.adopt(v1, inRegistry: false, deviceID: "t", today: today, now: now)
        #expect(r1.proposals.contains { $0.raw["provenance"]?["repair"] == .array([.str("priority")]) })
    }

    // Layer 5 second review, finding 3: a repair card's follow-up date never falls after the item's deadline, and the
    // item's other derivation flags stay.
    @Test func aRepairCardFollowsUpBeforeTheDeadline() throws {
        let waiting = #"{"id":"w-1","title":"Invented wait","status":"waiting","priority":"normal","due":"2026-10-08","derived":["due"]}"#
        let result = try Adoption.adopt(try lifeproj([waiting]), inRegistry: false, deviceID: "t", today: today, now: now)
        let card = try #require(result.proposals.first { $0.raw["provenance"]?["repair"] != nil })
        let set = card.ops.first?["args"]?["set"]
        #expect(set?["follow_up_at"] == .str("2026-10-08"))
        #expect(set?["derived"] == .array([.str("due"), .str("follow_up_at")]))
    }

    // An item that breaks the rules only in a way a mechanical fix repairs gets the fix, not an empty repair card.
    @Test func aBrokenItemTheMechanicalFixRepairsGetsNoCard() throws {
        let folder = try lifeproj([#"{"id":"n-1","title":"Invented task","status":"open","priority":"normal","due":null,"no_deadline":true}"#,
                                   #"{"id":"c-1","title":"Invented filing","status":"open","priority":"normal","due":"20261101"}"#])
        let url = folder.appendingPathComponent("catalog.json")
        try Data(try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: #""name":"tax""#,
            with: #""name":"tax","format":"teka","format_version":"0","disclosure":"none""#).utf8).write(to: url)
        #expect(Teka.read(folder).level == .tekaV0 && Teka.read(folder).findings.count == 2)
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now)
        #expect(result.mechanical.count == 2)
        #expect(!result.proposals.contains { $0.raw["provenance"]?["repair"] != nil })
        let teka = Teka.read(folder)
        #expect(teka.findings.isEmpty && teka.state == .ready, "\(teka.reasons)")
        #expect(teka.items.first { $0.idText == "c-1" }?.object?["due"] == .str("2026-11-01"))
    }

    // A finding about anything but an open item (layer 3 reports `documents[i]` too) makes no repair card, and only
    // a strictly written `open_items[<digits>]` names an item.
    @Test func onlyOpenItemFindingsMakeRepairCards() throws {
        let items: [JSONValue] = [.obj([("id", .str("a-1")), ("title", .str("Invented task")), ("status", .str("open"))])]
        let actor = JSONObject([(key: "kind", value: .str("import"))])
        func cards(_ location: String) -> Int {
            Adoption.repairCards([(.missingField, location, "priority")], items: items, today: today, actor: actor, now: now).count
        }
        #expect(cards("documents[10]") == 0)
        #expect(cards("documents[0]") == 0)
        #expect(cards("open_items[+0]") == 0)
        #expect(cards("open_items[0") == 0)
        #expect(cards("open_items[0]") == 1)
        #expect(Adoption.itemIndex("open_items[12]") == 12)
        #expect(Adoption.itemIndex("open_items[]") == nil)
        #expect(Adoption.itemIndex("open_items[١]") == nil)
    }

    // Layer 5 second review, finding 5: an adoption cut short after its snapshot is finished by running it again,
    // with no second snapshot and no card saved twice.
    @Test func anInterruptedAdoptionResumes() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        let proposalsDir = folder.appendingPathComponent(".sprava/proposals")
        try FileManager.default.createDirectory(at: proposalsDir, withIntermediateDirectories: true)
        chmod(proposalsDir.path, 0o500)
        #expect(throws: (any Error).self) { try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now) }
        chmod(proposalsDir.path, 0o700)
        #expect(ProposalStore.list(in: folder).isEmpty)

        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now.addingTimeInterval(60))
        #expect(result.proposals.map(\.title) == ["Close 1 item(s) already marked done", "Stamp this binder as binder v0"])
        let store = TekaStore(folder: folder)
        #expect(try store.readOpLog().ops.filter { $0["op"] == .str("import_snapshot") }.count == 1)
        #expect(try store.readOpLog().ops.filter { $0["op"] == .str("update_item") }.count == 1)
        #expect(throws: TekaStore.Refused.self) { try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now) }

        // Cut short after some cards were saved: the saved ones are returned, not written again.
        try Data().write(to: Adoption.unfinishedMarker(folder))
        let again = try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now.addingTimeInterval(120))
        #expect(again.proposals.map(\.id) == result.proposals.map(\.id))
        #expect(ProposalStore.list(in: folder).count == 2)
        #expect(!FileManager.default.fileExists(atPath: Adoption.unfinishedMarker(folder).path))
    }

    // Layer 5 second review, finding 6: a meta value v0 rejects is kept aside on the stamp card, so the stamped
    // binder is ready; a catalog that would still not read as ready gets no stamp.
    @Test func theStampKeepsAsideMetaValuesV0Rejects() throws {
        let plain = #"{"id":"p-1","title":"Invented task","status":"open","priority":"normal","due":"2026-11-01"}"#
        let folder = try lifeproj([plain])
        let url = folder.appendingPathComponent("catalog.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        try Data(text.replacingOccurrences(of: #""name":"tax""#, with: #""name":"tax","lifecycle":"legacy","modules":"ledger""#).utf8).write(to: url)
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now)
        let stamp = try #require(result.proposals.first { $0.raw["provenance"]?["adoption"] == .str("stamp") })
        #expect(stamp.ops.map { $0["op"]?.stringValue ?? "" } == ["set_meta", "migrate"])
        try TekaStore(folder: folder).approve(stamp, now: now)
        let teka = Teka.read(folder)
        #expect(teka.state == .ready, "\(teka.reasons)")
        #expect(teka.catalog?["meta"]?["legacy_lifecycle"] == .str("legacy"))
        #expect(teka.catalog?["meta"]?["legacy_modules"] == .str("ledger"))
        #expect(teka.catalog?["meta"]?["lifecycle"] == nil)

        // A name that differs from the folder's is the person's to settle (rename_teka): no stamp is offered.
        let other = try lifeproj([plain])
        let otherURL = other.appendingPathComponent("catalog.json")
        try Data(try String(contentsOf: otherURL, encoding: .utf8).replacingOccurrences(of: #""name":"tax""#, with: #""name":"tax-old""#).utf8)
            .write(to: otherURL)
        let r = try Adoption.adopt(other, inRegistry: false, deviceID: "t", today: today, now: now)
        #expect(!r.proposals.contains { $0.raw["provenance"]?["adoption"] == .str("stamp") })
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: other.appendingPathComponent(".sprava").path)).contains { $0.hasPrefix("probe-") })
    }

    // Layer 5 third review, finding 2: the cards adoption returns carry the fingerprints they were saved with, so an
    // item reopened after adoption is not closed by approving the returned card.
    @Test func aReturnedCardNoticesAnItemChangedSince() throws {
        let done = #"{"id":"d-1","title":"Invented finished task","status":"done","priority":"normal","due":"2026-11-01"}"#
        let folder = try lifeproj([done])
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now)
        let close = try #require(result.proposals.first { $0.title.hasPrefix("Close ") })
        #expect(close.raw["expect"]?.objectValue?.entries.isEmpty == false)
        // The person sets the item back to open in an editor.
        let url = folder.appendingPathComponent("catalog.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""status":"done""#))
        try Data(text.replacingOccurrences(of: #""status":"done""#, with: #""status":"open""#).utf8).write(to: url)
        #expect(throws: TekaStore.Refused.self) { try TekaStore(folder: folder).approve(close, now: now) }
        #expect(Teka.read(folder).items.first { $0.idText == "d-1" }?.object?["status"] == .str("open"))
    }

    // Layer 5 third review, finding 5: a fix that cannot be written (an op log that is read-only) stops the
    // adoption with its marker in place, so running it again finishes it.
    @Test func aFixThatCannotBeWrittenStopsTheAdoption() throws {
        let folder = try lifeproj([#"{"id":"n-1","title":"Invented task","status":"open","priority":"normal","due":"2026-11-01","link":null}"#])
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        try Data().write(to: Adoption.unfinishedMarker(folder))
        let log = folder.appendingPathComponent(".sprava/ops.ndjson")
        chmod(log.path, 0o444)
        defer { chmod(log.path, 0o644) }
        #expect(throws: AtomicFile.Failure.self) { try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now) }
        #expect(FileManager.default.fileExists(atPath: Adoption.unfinishedMarker(folder).path))
        chmod(log.path, 0o644)
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now)
        #expect(result.mechanical.count == 1)
        #expect(!FileManager.default.fileExists(atPath: Adoption.unfinishedMarker(folder).path))
    }
}
