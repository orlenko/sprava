import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct IntakeTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    struct Setup {
        let commands: Commands
        let folder: URL
        let watcher: IntakeWatcher
    }

    func setup() throws -> Setup {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-intake-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        try adoptAsCommand(folder, commands: commands, now: now, today: today)
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: now) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        return Setup(commands: commands, folder: folder, watcher: IntakeWatcher(support: support))
    }

    func drop(_ s: Setup, _ name: String, _ text: String = "invented letter body") throws {
        try Data(text.utf8).write(to: s.folder.appendingPathComponent("intake/\(name)"))
    }

    @Test func dotFilesMailLinksAndFoldersAreSkipped() throws {
        let s = try setup()
        try drop(s, ".DS_Store")
        try FileManager.default.createDirectory(at: s.folder.appendingPathComponent("intake/mail"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: s.folder.appendingPathComponent("intake/_converted"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: s.folder.appendingPathComponent("intake/scans"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: s.folder.appendingPathComponent("intake/elsewhere.pdf"),
                                                   withDestinationURL: s.folder.appendingPathComponent("catalog.json"))
        #expect(IntakeWatcher.candidates(in: s.folder).isEmpty)
    }

    @Test func aMoveCutShortIsRolledForwardOrAborted() throws {
        let s = try setup()
        let store = TekaStore(folder: s.folder)
        try drop(s, "deed.pdf")
        let sha = try #require(DocumentPaths.sha256(of: s.folder.appendingPathComponent("intake/deed.pdf")))
        let catalogBefore = try Data(contentsOf: s.folder.appendingPathComponent("catalog.json"))
        let snapshotBefore = try Data(contentsOf: s.folder.appendingPathComponent(".sprava/snapshot.json"))
        func file() -> TekaStore.OpBody {
            .init(op: "file_document", args: JSONObject([
                (key: "document", value: .obj([("id", .str("estate-example-doc-2026-901")), ("title", .str("Deed")),
                                               ("path", .str("documents/deed.pdf")), ("sha256", .string(sha))])),
                (key: "from", value: .str("intake/deed.pdf"))]), actor: JSONObject([(key: "kind", value: .str("user"))]))
        }
        try store.apply([file()], now: now)
        // The crash: the op is logged, but the move and the rename never happened.
        try FileManager.default.moveItem(at: s.folder.appendingPathComponent("documents/deed.pdf"), to: s.folder.appendingPathComponent("intake/deed.pdf"))
        try catalogBefore.write(to: s.folder.appendingPathComponent("catalog.json"))
        try snapshotBefore.write(to: s.folder.appendingPathComponent(".sprava/snapshot.json"))
        try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: .str("estate-example-2026-007")),
                                                                    (key: "set", value: .obj([("priority", .str("low"))]))]),
                               actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        #expect(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("documents/deed.pdf").path))
        #expect(Teka.read(s.folder).catalog?["documents"]?.arrayValue?.contains { $0["path"] == .str("documents/deed.pdf") } == true)
        _ = try Replay.run(try store.readOpLog().ops)

        // Again, but the file is gone from both places: the write is aborted, never half applied.
        try drop(s, "will.pdf")
        let sha2 = try #require(DocumentPaths.sha256(of: s.folder.appendingPathComponent("intake/will.pdf")))
        let catalog2 = try Data(contentsOf: s.folder.appendingPathComponent("catalog.json"))
        let snapshot2 = try Data(contentsOf: s.folder.appendingPathComponent(".sprava/snapshot.json"))
        try store.apply([.init(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", .str("estate-example-doc-2026-902")), ("title", .str("Will")),
                                           ("path", .str("documents/will.pdf")), ("sha256", .string(sha2))])),
            (key: "from", value: .str("intake/will.pdf"))]), actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        try FileManager.default.removeItem(at: s.folder.appendingPathComponent("documents/will.pdf"))
        try catalog2.write(to: s.folder.appendingPathComponent("catalog.json"))
        try snapshot2.write(to: s.folder.appendingPathComponent(".sprava/snapshot.json"))
        try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: .str("estate-example-2026-007")),
                                                                    (key: "set", value: .obj([("priority", .str("high"))]))]),
                               actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        let ops = try store.readOpLog().ops
        #expect(ops.contains { $0["op"] == .str("abort") })
        #expect(Teka.read(s.folder).catalog?["documents"]?.arrayValue?.contains { $0["path"] == .str("documents/will.pdf") } == false)
        _ = try Replay.run(ops)
    }

    @Test func theGuardRefusesUnsafeFilings() throws {
        let s = try setup()
        try drop(s, "x.pdf")
        let sha = try #require(DocumentPaths.sha256(of: s.folder.appendingPathComponent("intake/x.pdf")))
        for (path, from) in [("CLAUDE.md", "intake/x.pdf"), ("documents/x.pdf", "documents/other.pdf"), ("scripts/x.pdf", "intake/x.pdf")] {
            #expect(throws: (any Error).self) {
                try TekaStore(folder: s.folder).apply([.init(op: "file_document", args: JSONObject([
                    (key: "document", value: .obj([("id", .str("d-1")), ("title", .str("X")), ("path", .string(path)), ("sha256", .string(sha))])),
                    (key: "from", value: .string(from))]), actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
            }
        }
        #expect(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("intake/x.pdf").path))
    }
}
