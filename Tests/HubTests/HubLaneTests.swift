import BinderFormat
import BinderStore
import Foundation
@testable import Hub
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct HubLaneTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func adoptedBinder() throws -> (URL, URL) {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        _ = try Adoption.adopt(folder, inRegistry: true, deviceID: "t", today: today, now: now)
        let spool = folder.deletingLastPathComponent().appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (folder, spool)
    }

    func slice(_ spool: URL) throws -> JSONValue {
        try JSONParser.parse(try Data(contentsOf: spool.appendingPathComponent("inbox/rental-elm-street.agenda.json"))).value
    }

    @Test func noSpoolIsAQuietNoOp() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        let missing = folder.deletingLastPathComponent().appendingPathComponent("no-spool")
        #expect(try HubLane.publish(folder, root: missing, now: now) == .noSpool)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func publishesOnceThenSkipsUnchanged() throws {
        let (folder, spool) = try adoptedBinder()
        #expect(try HubLane.publish(folder, root: spool, now: now) == .published(items: 4, overwrittenByOther: false))
        #expect(try HubLane.publish(folder, root: spool, now: now) == .unchanged)
        let mode = try FileManager.default.attributesOfItem(atPath: spool.appendingPathComponent("inbox/rental-elm-street.agenda.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try slice(spool)["items"]?.arrayValue?.first?["id"] == .str("rental-elm-street-item-0003"))
    }

    @Test func aSliceOverwrittenByAnotherProgramIsNoticed() throws {
        let (folder, spool) = try adoptedBinder()
        _ = try HubLane.publish(folder, root: spool, now: now)
        let target = spool.appendingPathComponent("inbox/rental-elm-street.agenda.json")
        try Data(#"{"teka":"rental-elm-street","generated":"2026-10-07T00:00:00Z","items":[]}"#.utf8).write(to: target)
        #expect(try HubLane.publish(folder, root: spool, now: now) == .published(items: 4, overwrittenByOther: true))
    }

    @Test func drainAppliesDoneAndDroppedAndKeepsTheRest() throws {
        let (folder, spool) = try adoptedBinder()
        let outbox = spool.appendingPathComponent("outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("""
        {"teka": "rental-elm-street", "items": [{"title": "routed capture"}],
         "completions": [
          {"id": "rental-elm-street-item-0003", "action": "done", "at": "2026-10-07T08:00:00Z", "source": "google-tasks-via-osavul"},
          {"id": "item-0006", "action": "dropped", "at": "2026-10-07T08:01:00Z"},
          {"id": "rental-elm-street-nope", "action": "done", "at": "2026-10-07T08:02:00Z"},
          {"id": "item-0003", "action": "archived"}
         ]}
        """.utf8).write(to: outbox.appendingPathComponent("rental-elm-street.intake.json"))
        let result = try HubLane.drain(folder, root: spool, now: now)
        #expect(result.applied == 2 && result.acknowledged == 2 && result.skipped == 2)
        let left = try JSONParser.parse(try Data(contentsOf: outbox.appendingPathComponent("rental-elm-street.intake.json"))).value
        #expect(left["completions"]?.arrayValue?.count == 2)       // unknown completions linger
        #expect(left["items"]?.arrayValue?.count == 1)             // items[] preserved
        let log = Teka.read(folder).catalog!["processing_log"]!.arrayValue!
        let drained = log.last { $0["id"] == .str("item-0006") }
        #expect(drained?["action"] == .str("dropped") && drained?["source"] == .str("osavul"))
        #expect(drained?["closed_at"] == .str("2026-10-07T08:01:00Z"))
        let ops = try TekaStore(folder: folder).readOpLog().ops
        #expect(ops.last?["actor"]?["origin"] == .str("spool-outbox"))
        // Re-running is a no-op.
        #expect(try HubLane.drain(folder, root: spool, now: now) == HubLane.DrainResult(applied: 0, acknowledged: 0, skipped: 2, waitingForYou: 0))
    }

    @Test func aFullyAppliedOutboxIsDeleted() throws {
        let (folder, spool) = try adoptedBinder()
        let outbox = spool.appendingPathComponent("outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = outbox.appendingPathComponent("rental-elm-street.intake.json")
        try Data(#"{"completions":[{"id":"item-0003","action":"done","at":"2026-10-07T08:00:00Z"}]}"#.utf8).write(to: file)
        _ = try HubLane.drain(folder, root: spool, now: now)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aSymlinkedInboxIsRefused() throws {
        let (folder, spool) = try adoptedBinder()
        try FileManager.default.createSymbolicLink(at: spool.appendingPathComponent("inbox"), withDestinationURL: FileManager.default.temporaryDirectory)
        #expect(throws: TekaStore.Refused.self) { try HubLane.publish(folder, root: spool, now: now) }
    }
}
