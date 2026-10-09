import Foundation
@testable import Shelf
import SpravaKit
import Testing

/// Regressions from the second review of the Shelf and Extract layer: shelf.json linked to state out of reach is
/// unreadable, never an empty shelf to save over. Invented data only.
@Suite(.serialized) struct LayerReview2Tests {
    @Test func aShelfLinkedToStateOutOfReachIsNeverSavedOver() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-layer06b-shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = ShelfStore(supportDirectory: support)
        let away = support.appendingPathComponent("unmounted-volume/shelf.json").path
        try FileManager.default.createSymbolicLink(atPath: store.file.path, withDestinationPath: away)
        let binder = URL(fileURLWithPath: "/Invented/binder-a", isDirectory: true)

        #expect(throws: StateFile.Unreadable.self) { try store.readFolders() }
        #expect(throws: StateFile.Unreadable.self) { try store.add(binder) }
        #expect(throws: StateFile.Unreadable.self) { try store.remove(binder) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: store.file.path) == away)

        // A missing file is still an empty shelf, and a save keeps the registry setting read under the lock.
        try FileManager.default.removeItem(at: store.file)
        try Data(#"{"schemaVersion": 1, "folders": [], "showRegistry": true}"#.utf8).write(to: store.file)
        try store.add(binder)
        #expect(store.showsRegistry)
        #expect(try store.readFolders().map(\.path) == [binder.path])
    }
}
