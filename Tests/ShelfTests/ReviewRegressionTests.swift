import Foundation
@testable import Shelf
import Testing

/// One test per confirmed finding of the increment-1 hostile review.
@Suite struct ReviewRegressionTests {
    @Test func unreadableShelfIsNeverOverwritten() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-rr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = ShelfStore(supportDirectory: support)
        try Data("{not the shape".utf8).write(to: store.file)
        #expect(throws: ShelfStore.Unreadable.self) { try store.add(support) }
        #expect(try String(contentsOf: store.file, encoding: .utf8) == "{not the shape")
    }
}
