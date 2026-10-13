import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import Testing

/// An empty folder the person picked becomes a new binder (mvp.md feature 1). Invented data only.
@Suite struct EmptyFolderBinderTests {
    let today = CalendarDate(year: 2026, month: 10, day: 7)!

    func parent() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aSyncedEmptyFolderInAnUnsyncedParentIsRefusedAndLeftAsItIs() throws {
        let parent = try parent()
        let picked = parent.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        // Stands in for an iCloud Desktop folder in a home folder that is not synced.
        let synced: (URL) -> Bool = { $0.standardizedFileURL.path == picked.standardizedFileURL.path }
        #expect(throws: TekaStore.Refused.self) {
            try BinderCreator.create(parent: parent, name: "desk", template: .blank, deviceID: "dev", knownNames: [],
                                     year: 2026, today: today, existing: picked, synced: synced)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["Desktop"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: picked.path).isEmpty)
    }

    @Test func onlyFinderMetadataCountsAsEmpty() throws {
        let folder = try parent()
        #expect(BinderCreator.isEmptyFolder(folder))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        #expect(BinderCreator.isEmptyFolder(folder))
        try Data("invented".utf8).write(to: folder.appendingPathComponent(".hidden"))
        #expect(!BinderCreator.isEmptyFolder(folder))
        #expect(!BinderCreator.isEmptyFolder(folder.appendingPathComponent("missing")))
        let many = try parent()
        for n in 0..<50 { try Data().write(to: many.appendingPathComponent("note-\(n).txt")) }
        #expect(!BinderCreator.isEmptyFolder(many))
    }
}
