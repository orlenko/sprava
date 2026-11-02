import BinderFormat
import BinderStore
import Foundation
import Services
import Shelf
import SpravaKit
import Testing

struct GeneralBinderCommandTests {
    @Test func freshGeneralIsOrdinaryPrivateWritableAndProtectedBeforeLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("general-command-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("binders"), support = root.appendingPathComponent("support")
        let commands = Commands(support: support, deviceID: "invented-device")
        func call(_ fields: [(String, JSONValue)]) throws -> JSONValue {
            try JSONParser.parse(commands.handle(JSONWriter.compact(.obj(fields)))).value
        }
        let request: [(String, JSONValue)] = [("command", .str("general_binder")), ("parent", .str(parent.path)), ("create_parent", .bool(true))]
        #expect(!FileManager.default.fileExists(atPath: parent.path))
        let first = try call(request)
        #expect(first["ok"] == .bool(true), "\(first)")
        let folder = URL(fileURLWithPath: try #require(first["binder"]?.stringValue))
        let teka = Teka.read(folder)
        #expect(teka.isAdopted && !teka.writesBlocked && teka.state == .ready)
        #expect(teka.catalog?["meta"]?["disclosure"] == .str("none"))
        #expect(try ShelfStore(supportDirectory: support).readFolders() == [folder])
        // A later Settings change and a lost reply keep the original binder and everything written to it.
        let added = try call([("command", .str("apply")), ("binder", .str(folder.path)), ("op", .str("add_item")),
                              ("args", .obj([("item", .obj([("id", .str("$new:1")), ("title", .str("Water the seedlings")),
                                  ("status", .str("open")), ("priority", .str("normal")), ("no_deadline", .bool(true))]))]))])
        #expect(added["ok"] == .bool(true), "\(added)")
        let second = try call([("command", .str("general_binder")), ("parent", .str(root.appendingPathComponent("elsewhere").path))])
        #expect(second["binder"] == first["binder"] && Teka.read(folder).items.count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("elsewhere").path))
        for fields: [(String, JSONValue)] in [
            [("command", .str("shelf_remove"))], [("command", .str("transfer"))],
            [("command", .str("backup_request")), ("kind", .str("offload"))],
        ] {
            let request = fields + [("binder", .str(folder.path))]
            #expect(commands.generalRetirementRefusal(JSONWriter.compact(.obj(request))) != nil)
            #expect(try call(request)["ok"] == .bool(false))
        }
        #expect(try ShelfStore(supportDirectory: support).readFolders() == [folder])
        #expect(commands.generalRetirementRefusal(JSONWriter.compact(.obj([
            ("command", .str("backup_request")), ("kind", .str("backup_now")), ("binder", .str(folder.path)),
        ]))) == nil)
    }

    @Test func anExistingGeneralNameIsPreservedAndBrokenShelfDoesNotCreate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("general-collision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("binders"), support = root.appendingPathComponent("support")
        let existing = parent.appendingPathComponent("general/kept.txt")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Invented existing document".utf8).write(to: existing)
        let commands = Commands(support: support, deviceID: "invented-device")
        let request = JSONWriter.compact(.obj([("command", .str("general_binder")), ("parent", .str(parent.path))]))
        _ = try StateDirectory.open(support, create: true)
        try Data("damaged shelf".utf8).write(to: support.appendingPathComponent("shelf.json"))
        #expect(try JSONParser.parse(commands.handle(request)).value["ok"] == .bool(false))
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("general-2").path))
        try FileManager.default.removeItem(at: support.appendingPathComponent("shelf.json"))
        let result = try JSONParser.parse(commands.handle(request)).value
        #expect(result["binder"]?.stringValue?.hasSuffix("/general-2") == true)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "Invented existing document")
    }
}
