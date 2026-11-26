import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import Testing

@Suite struct PersonPageWritingTests {
    @Test func aReadingSurvivesReopeningAndConcurrentChangesArePreserved() throws {
        let (folder, store) = try StoreTests().adopted()
        defer { try? FileManager.default.removeItem(at: folder) }
        let doc = try #require(Teka.read(folder).catalog?["documents"]?.arrayValue?.first)
        let id = try #require(doc["id"]), path = try #require(doc["path"]?.stringValue)
        let file = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Invented garden page".utf8).write(to: file)
        let digest = try #require(DocumentPaths.sha256(of: file))
        let reading = try #require(PersonPageReading(revision: digest, page: 3, text: "Plant the moonflower at dusk."))
        let mark = try #require(PersonPageReading(revision: digest, page: 3, text: ""))
        try store.savePageReading(reading, documentID: id, path: path, expected: nil)
        let reopened = TekaStore(folder: folder)
        #expect(throws: TekaStore.Refused.self) { try reopened.savePageReading(mark, documentID: id, path: path, expected: nil) }
        try reopened.savePageReading(mark, documentID: id, path: path, expected: reading.text)
        try Data("Different edition".utf8).write(to: file)
        #expect(throws: TekaStore.Refused.self) { try store.savePageReading(reading, documentID: id, path: path, expected: "") }
        let current = try #require(Teka.read(folder).catalog?["documents"]?.arrayValue?.first)
        #expect(PersonPageReading.list(in: current) == [mark])
    }
}
