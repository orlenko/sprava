import BinderFormat
import BinderStore
import Foundation
@testable import Services
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

    @Test func aClosedItemShowsOnceAsDoneThenDrops() throws {
        let (folder, spool) = try adoptedBinder()
        _ = try HubLane.publish(folder, root: spool, now: now)
        let c = Commands(support: folder.deletingLastPathComponent().appendingPathComponent("s"), deviceID: "t")
        _ = c.handle(JSONWriter.compact(.obj([("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("complete")),
                                              ("args", .obj([("id", .str("item-0003")), ("closed_at", .str("2026-10-07T09:00:00Z")), ("source", .str("user"))]))])))
        _ = try HubLane.publish(folder, root: spool, now: now)
        let once = try slice(spool)["items"]!.arrayValue!.first { $0["id"] == .str("rental-elm-street-item-0003") }
        #expect(once?["status"] == .str("done"))
        _ = try HubLane.publish(folder, root: spool, now: now)
        #expect(try slice(spool)["items"]!.arrayValue!.contains { $0["id"] == .str("rental-elm-street-item-0003") } == false)
    }
}
