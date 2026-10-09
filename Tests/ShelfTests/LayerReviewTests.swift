import Foundation
@testable import Shelf
import SpravaKit
import Testing

/// Regressions from the review of the Shelf and Extract layer: recent.json is never saved over when it cannot be
/// read. Invented data only.
@Suite(.serialized) struct LayerReviewTests {
    func temp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-layer06-\(label)-\(UUID().uuidString)")
    }

    // MARK: - 7. Opening a binder never overwrites unreadable recent history

    @Test func unreadableRecentHistoryIsLeftAsItIs() throws {
        let support = temp("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let recent = RecentBinders(supportDirectory: support)
        let binder = URL(fileURLWithPath: "/Invented/binder-a", isDirectory: true)
        #expect(try recent.readOpened().isEmpty)   // a missing file is no history

        for bytes in [#"{"/Invented/binder-b": "2026-10-01T09:00:00-04:00", "#,                                     // malformed
                      #"{"/Invented/binder-b": "2026-10-01T09:00:00-04:00", "/Invented/binder-c": "last week"}"#] {  // one bad date
            try Data(bytes.utf8).write(to: recent.file)
            #expect(throws: StateFile.Unreadable.self) { try recent.readOpened() }
            #expect(throws: StateFile.Unreadable.self) { try recent.touch(binder) }
            #expect(try Data(contentsOf: recent.file) == Data(bytes.utf8))
            #expect(recent.opened().isEmpty)
        }

        try FileManager.default.removeItem(at: recent.file)
        let t = Date(timeIntervalSince1970: 1_791_360_000)
        try recent.touch(binder, now: t)
        #expect(try recent.readOpened() == [binder.standardizedFileURL.path: t])
    }

    @Test func aRecentHistoryThatCannotBeWrittenThrows() throws {
        let blocked = temp("blocked")
        try Data("not a folder".utf8).write(to: blocked)   // the support folder is a file
        #expect(throws: (any Error).self) {
            try RecentBinders(supportDirectory: blocked).touch(URL(fileURLWithPath: "/Invented/binder-a", isDirectory: true))
        }
    }
}
