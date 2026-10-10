import BinderFormat
import Foundation
@testable import Hub
import Shelf
import SpravaKit
import Testing

/// Regression tests for the Bugbot pass on the final hub fixes. Each test names the finding it pins. Every value is
/// invented.
@Suite(.serialized) struct ReviewRegression5Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-hub5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func binder(_ parent: URL, folder: String, catalog: String) throws -> URL {
        let f = parent.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try Data(catalog.utf8).write(to: f.appendingPathComponent("catalog.json"))
        return f
    }

    // q-0-8. A known binder whose catalog is corrupt still holds its folder's name on the spool: a healthy binder of
    // the same name collides with it. A folder that is not a binder takes no part.
    @Test func aCorruptBinderStillTakesPartInNameCollisions() throws {
        let root = try scratch()
        let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
        let healthy = try binder(one, folder: "tax",
                                 catalog: #"{"meta":{"schema_version":2,"name":"tax"},"open_items":[],"processing_log":[]}"#)
        let corrupt = try binder(two, folder: "Tax", catalog: "{ invalid")
        #expect(Teka.read(corrupt).catalog == nil)
        let rows = Shelf.rows(registry: nil, picked: [healthy, corrupt])
        let today = CalendarDate.today(now: now)
        #expect(HubLane.collidingFolders(rows, today: today) == [healthy.standardizedFileURL.path, corrupt.standardizedFileURL.path])

        let plain = root.appendingPathComponent("three/tax", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(HubLane.collidingFolders(Shelf.rows(registry: nil, picked: [healthy, plain]), today: today).isEmpty)
    }
}
