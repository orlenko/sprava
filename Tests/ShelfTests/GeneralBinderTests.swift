import Foundation
import Shelf
import SpravaKit
import Testing

struct GeneralBinderTests {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("general-binding-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func readingIsLazyAndConcurrentRequestsKeepOneFolder() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support"), folder = root.appendingPathComponent("general")
        let binding = GeneralBinder(support: support)
        #expect(try !binding.protects(folder))
        #expect(!FileManager.default.fileExists(atPath: support.path))
        let results = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try GeneralBinder(support: support).ensure {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                        return folder
                    }
                }
            }
            var paths: [URL] = []
            for try await result in group { paths.append(result) }
            return paths
        }
        #expect(results.count == 8 && Set(results.map(\.path)) == [folder.resolvingSymlinksInPath().path])
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        #expect(try binding.protects(alias))
        #expect(try binding.protects(folder))
    }

    @Test func aMissingOrReplacedFolderIsNeverSilentlyRecreated() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = GeneralBinder(support: root.appendingPathComponent("support")), folder = root.appendingPathComponent("general")
        _ = try binding.ensure { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); return folder }
        let original = root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: folder, to: original)
        #expect(throws: GeneralBinder.Unavailable.self) { try binding.ensure { Issue.record("must not recreate"); return folder } }
        #expect(try binding.protects(folder))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(throws: GeneralBinder.Unavailable.self) { try binding.ensure { Issue.record("must not replace"); return folder } }
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: original, to: folder)
        #expect(try binding.ensure { Issue.record("must reuse"); return folder } == folder.resolvingSymlinksInPath())
    }

    @Test func unreadableStateRefusesRetirementInsteadOfTreatingItAsAbsent() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support"), state = support.appendingPathComponent("shelf/general.sqlite")
        _ = try StateDirectory.open(state.deletingLastPathComponent(), create: true)
        try Data("damaged".utf8).write(to: state)
        #expect(throws: (any Error).self) { try GeneralBinder(support: support).protects(root.appendingPathComponent("general")) }
        #expect(try Data(contentsOf: state) == Data("damaged".utf8))
    }
}
