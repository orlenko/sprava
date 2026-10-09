import BinderFormat
import CryptoKit
import Foundation
@testable import Shelf
import SpravaKit
import Testing

/// Regressions from Codex Bugbot's review of the Shelf and Extract layer (PR #11): a binder's opaque label cannot be
/// matched to a guessed path, a newer shelf.json is never rewritten, shelf.json is written by `AtomicFile`.
/// Invented data only.
@Suite(.serialized) struct BugbotReviewTests {
    func temp(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot06-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The opaque label is keyed, so it cannot be matched against guessed paths

    @Test func anOpaqueLabelIsKeyedNotAHashOfThePath() throws {
        let folder = temp("binders").appendingPathComponent("estate-secret", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let row = ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))   // no catalog: disclosure none
        let list = FilingList(support: temp("support"))

        let label = try list.name(of: row)
        #expect(label.hasPrefix("binder-") && label.count == "binder-".count + 6)
        #expect(!label.contains("estate"))
        // Anyone can compute the plain hash of a guessed path; the label is not it.
        let plain = "binder-" + SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
        #expect(label != plain)
        // Stable on this Mac, made from a private 32-byte key.
        #expect(try list.name(of: row) == label)
        #expect(try FilingList(support: list.support).name(of: row) == label)
        let attributes = try FileManager.default.attributesOfItem(atPath: list.keyURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try Data(contentsOf: list.keyURL).count == 32)
        #expect(try FileManager.default.contentsOfDirectory(atPath: list.support.path) == ["label-key"])

        // A key that exists but does not read is never replaced, and no label is given.
        let broken = FilingList(support: temp("support-broken"))
        try AtomicFile.makePrivateFolder(broken.support)
        try Data("short".utf8).write(to: broken.keyURL)
        #expect(throws: StateFile.Unreadable.self) { try broken.name(of: row) }
        #expect(try Data(contentsOf: broken.keyURL) == Data("short".utf8))
    }

    // MARK: - A shelf.json from a newer Sprava is never rewritten

    @Test func aNewerShelfIsNeverRewritten() throws {
        let support = temp("shelf-newer")
        let store = ShelfStore(supportDirectory: support)
        let newer = Data(#"{"schemaVersion": 2, "folders": ["/Invented/binder-a"], "pinned": ["/Invented/binder-a"]}"#.utf8)
        try newer.write(to: store.file)
        let binder = URL(fileURLWithPath: "/Invented/binder-b", isDirectory: true)
        #expect(throws: StateFile.Unreadable.self) { try store.add(binder) }
        #expect(throws: StateFile.Unreadable.self) { try store.remove(URL(fileURLWithPath: "/Invented/binder-a", isDirectory: true)) }
        #expect(try Data(contentsOf: store.file) == newer)
    }

    // MARK: - recent.json that is a FIFO is unreadable at once, never waited on

    @Test func aRecentFileThatIsAFIFOIsRefusedAtOnce() throws {
        let support = temp("recent-fifo")
        let recent = RecentBinders(supportDirectory: support)
        #expect(mkfifo(recent.file.path, 0o600) == 0)
        let start = Date()
        #expect(throws: StateFile.Unreadable.self) { try recent.readOpened() }
        #expect(throws: StateFile.Unreadable.self) { try recent.touch(URL(fileURLWithPath: "/Invented/binder-a", isDirectory: true)) }
        #expect(recent.opened().isEmpty)
        #expect(Date().timeIntervalSince(start) < 5)
        var st = stat()
        #expect(lstat(recent.file.path, &st) == 0 && st.st_mode & S_IFMT == S_IFIFO)   // left as it is
    }

    // MARK: - shelf.json is written by AtomicFile: private, whole, no temporary file left behind

    @Test func theShelfIsWrittenPrivatelyAndWhole() throws {
        let support = temp("shelf-atomic")
        let store = ShelfStore(supportDirectory: support)
        try store.add(URL(fileURLWithPath: "/Invented/binder-a", isDirectory: true))
        try store.add(URL(fileURLWithPath: "/Invented/binder-b", isDirectory: true))
        #expect(try store.readFolders().map(\.path) == ["/Invented/binder-a", "/Invented/binder-b"])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: support.path)) == ["shelf.json", "shelf.lock"])
    }
}
