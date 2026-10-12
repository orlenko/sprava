import BinderFormat
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The Shelf's commands, which the runtime carries out for the app, and the read the app makes itself. Invented
/// binders in temporary folders.
@Suite(.serialized) struct ShelfCommandsTests: BinderCommandFixture {
    @Test func addingAndRemovingWriteOnlyTheShelf() throws {
        let c = commands()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "kitchen-reno")
        let before = try Data(contentsOf: binder.appendingPathComponent("catalog.json"))
        let added = try call(c, [("command", .str("shelf_add")), ("binder", .string(binder.path))])
        #expect(added["ok"] == .bool(true) && added["name"] == .string(Teka.read(binder).name))
        #expect(try ShelfStore(supportDirectory: c.support).readFolders().map(\.standardizedFileURL) == [binder.standardizedFileURL])
        #expect(try Data(contentsOf: binder.appendingPathComponent("catalog.json")) == before)
        #expect(try call(c, [("command", .str("shelf_remove")), ("binder", .string(binder.path))])["ok"] == .bool(true))
        #expect(try ShelfStore(supportDirectory: c.support).readFolders().isEmpty)
    }

    @Test func aFolderWithoutACatalogOrARelativePathIsRefused() throws {
        let c = commands()
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-not-a-binder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let r = try call(c, [("command", .str("shelf_add")), ("binder", .string(empty.path))])
        #expect(r["ok"] == .bool(false) && r["error"]?.stringValue?.contains("not a binder") == true)
        #expect(try call(c, [("command", .str("shelf_add")), ("binder", .str("relative/kitchen"))])["ok"] == .bool(false))
        #expect(try ShelfStore(supportDirectory: c.support).readFolders().isEmpty)
    }

    @Test func theSnapshotOrdersByLastOpenedAndSaysWhatItCouldNotRead() throws {
        let c = commands()
        let a = try makeTeka(fixture: "sprava-v0", folderName: "kitchen-reno")
        let b = try makeTeka(fixture: "sprava-v0", folderName: "garden-shed")
        try ShelfStore(supportDirectory: c.support).add(a)
        try ShelfStore(supportDirectory: c.support).add(b)
        try RecentBinders(supportDirectory: c.support).touch(b)
        let snapshot = ShelfSnapshot.read(support: c.support)
        #expect(snapshot.rows.map(\.folder.standardizedFileURL) == [b, a].map(\.standardizedFileURL) && snapshot.note == nil)
        try Data("{ not json".utf8).write(to: ShelfStore(supportDirectory: c.support).file)
        let broken = ShelfSnapshot.read(support: c.support)
        #expect(broken.rows.isEmpty && broken.note != nil)
    }
}
