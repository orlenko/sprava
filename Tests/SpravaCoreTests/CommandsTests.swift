import Foundation
import Testing
@testable import SpravaCore

@Suite(.serialized) struct CommandsTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func setup() throws -> (Commands, URL) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-cmd-\(UUID().uuidString)")
        return (Commands(support: support, deviceID: "dev"), try makeTeka(fixture: "lifeproj-v2-live"))
    }

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    @Test func adoptListApproveThroughCommands() throws {
        let (c, folder) = try setup()
        let adopted = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
        #expect(adopted["ok"] == .bool(true))
        let listed = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])
        let cards = try #require(listed["proposals"]?.arrayValue)
        #expect(cards.count == 2 && cards.allSatisfy { $0["verified"] == .bool(true) })
        for card in cards {
            let r = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)),
                                 ("proposal", card["id"]!), ("digest", card["digest"]!)])
            #expect(r["ok"] == .bool(true), "\(r)")
        }
        #expect(Teka.read(folder).state == .ready)
    }

    @Test func aStaleOrForeignCardCannotBeApproved() throws {
        let (c, folder) = try setup()
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
        let card = try #require(try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue?.first)
        let stale = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)),
                                 ("proposal", card["id"]!), ("digest", .str("sha256:00"))])
        #expect(stale["ok"] == .bool(false))
        // A proposal file another program dropped in is listed as not verified and refused.
        let foreign = Proposal.make(title: "Close everything", actor: JSONObject([(key: "kind", value: .str("clerk"))]), ops: [], now: now)
        let digest = try ProposalStore.save(foreign, in: folder)
        let listed = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])
        #expect(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(foreign.id) }?["verified"] == .bool(false))
        let r = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)),
                             ("proposal", .string(foreign.id)), ("digest", .string(digest))])
        #expect(r["ok"] == .bool(false))
    }

    @Test func directActionsAreLimitedAndAttributedToTheUser() throws {
        let (c, folder) = try setup()
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
        let done = try call(c, [("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("complete")),
                                ("args", .obj([("id", .str("item-0003")), ("closed_at", .str("2026-10-07T09:00:00Z")), ("source", .str("user"))]))])
        #expect(done["ok"] == .bool(true))
        let ops = try TekaStore(folder: folder).readOpLog().ops
        #expect(ops.last?["actor"]?["kind"] == .str("user"))
        let refused = try call(c, [("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("external_edit")),
                                   ("args", .obj([("patch", .array([]))]))])
        #expect(refused["ok"] == .bool(false))
        let relative = try call(c, [("command", .str("proposals")), ("binder", .str("relative/path"))])
        #expect(relative["ok"] == .bool(false))
    }
}

@Suite struct UUIDv7Tests {
    @Test func idsIncreaseWithinOneMillisecond() {
        let at = Date(timeIntervalSince1970: 1_791_360_000)
        let ids = (0..<5000).map { _ in UUIDv7.make(now: at) }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.count == 36 && $0[$0.index($0.startIndex, offsetBy: 14)] == "7" })
    }
}

@Suite struct OwnerTests {
    @Test func anotherDevicesBinderIsReadOnly() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-own-\(UUID().uuidString)")
        let mine = Commands(support: support, deviceID: "this-mac")
        let other = Commands(support: support, deviceID: "other-mac")
        _ = mine.handle(JSONWriter.compact(.obj([("command", .str("adopt")), ("binder", .string(folder.path))])))
        #expect(Owner.device(of: folder) == "this-mac")
        let r = try JSONParser.parse(other.handle(JSONWriter.compact(.obj([
            ("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("drop")),
            ("args", .obj([("id", .str("item-0006")), ("closed_at", .str("2026-10-07T09:00:00Z")), ("source", .str("user"))]))])))).value
        #expect(r["ok"] == .bool(false))
    }
}
