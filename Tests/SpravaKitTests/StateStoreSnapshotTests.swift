import Foundation
@testable import SpravaKit
import Testing

@Suite struct StateStoreSnapshotTests {
    @Test func aSnapshotIncludesWALCommitsAndNeedsNoSidecar() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-state-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.sqlite"), copy = folder.appendingPathComponent("copy.sqlite")
        let schema = StateStore.Schema(version: 1, statements: [])
        let writer = try StateStore.open(source, schema: schema)
        try writer.write { try $0.setDocument(["invented-before"], key: "value") }
        #expect(FileManager.default.fileExists(atPath: source.path + "-wal"))
        try StateStore.snapshot(source, to: copy)
        #expect(!FileManager.default.fileExists(atPath: copy.path + "-wal"))
        try writer.write { try $0.setDocument(["invented-after"], key: "value") }
        let restored = try StateStore.open(copy, schema: schema)
        #expect(try restored.read { try $0.document([String].self, key: "value") } == ["invented-before"])
    }

    @Test func aSnapshotRefusesExistingDestinationsAndLinkedSources() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-state-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.sqlite"), copy = folder.appendingPathComponent("copy.sqlite")
        let writer = try StateStore.open(source, schema: .init(version: 1, statements: []))
        let original = Data("invented destination".utf8)
        try original.write(to: copy)
        #expect(throws: (any Error).self) { try StateStore.snapshot(source, to: copy) }
        #expect(try Data(contentsOf: copy) == original)
        let link = folder.appendingPathComponent("link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let absent = folder.appendingPathComponent("absent.sqlite")
        #expect(throws: (any Error).self) { try StateStore.snapshot(link, to: absent) }
        #expect(!FileManager.default.fileExists(atPath: absent.path))
        #expect(try writer.read { try $0.rows("PRAGMA user_version").first?.first?.integer } == 1)
    }
}
