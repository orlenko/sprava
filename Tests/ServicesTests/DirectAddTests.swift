import BinderFormat
import BinderStore
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// An item the person adds in the app (the To-dos page's quick add): one `apply` of `add_item` whose id the runtime
/// mints under the binder's lock (binder-v0 §5.6, §6.5), and which Undo takes back. Invented data only.
@Suite(.serialized) struct DirectAddTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    func adopted() throws -> (Commands, URL) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-add-\(UUID().uuidString)")
        let c = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
        return (c, folder)
    }

    func add(_ c: Commands, _ folder: URL, _ title: String) throws -> JSONValue {
        try call(c, [("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("add_item")),
                     ("args", .obj([("item", .obj([("id", .str("$new:1")), ("title", .string(title)), ("status", .str("open")),
                                                   ("priority", .str("normal")), ("due", .str("2026-10-09"))]))]))])
    }

    @Test func aTypedItemGetsAMintedIdAndIsFiledAtOnce() throws {
        let (c, folder) = try adopted()
        let r = try add(c, folder, "Send the Acme invoice")
        #expect(r["ok"] == .bool(true), "\(r)")
        let items = Teka.read(folder).items
        let added = try #require(items.first { $0.title == "Send the Acme invoice" })
        #expect(added.idText.wholeMatch(of: /[a-z0-9-]+-2026-\d{3,}/) != nil, "\(added.idText)")
        #expect(!added.idText.contains("$new"))
        #expect(added.object?["created_at"] != nil)
        #expect(added.due?.description == "2026-10-09")
        let ops = try TekaStore(folder: folder).readOpLog().ops
        #expect(ops.last?["actor"]?["kind"] == .str("user"))
        #expect(ops.last?["proposal"] == nil)
    }

    @Test func twoTypedItemsGetTwoIds() throws {
        let (c, folder) = try adopted()
        let first = try add(c, folder, "Book the Harbor slip")
        let second = try add(c, folder, "Renew the Harbor permit")
        #expect(first["ok"] == .bool(true) && second["ok"] == .bool(true), "\(first) \(second)")
        let ids = Teka.read(folder).items.filter { ["Book the Harbor slip", "Renew the Harbor permit"].contains($0.title) }.map(\.idText)
        #expect(ids.count == 2 && Set(ids).count == 2, "\(ids)")
    }

    @Test func undoTakesTheTypedItemBack() throws {
        let (c, folder) = try adopted()
        let r = try add(c, folder, "Send the Acme invoice")
        let op = try #require(r["op"]?.stringValue)
        let undone = try call(c, [("command", .str("undo")), ("binder", .string(folder.path)), ("op_id", .string(op))])
        #expect(undone["ok"] == .bool(true), "\(undone)")
        #expect(!Teka.read(folder).items.contains { $0.title == "Send the Acme invoice" })
    }
}
