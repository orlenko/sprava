@testable import BinderStore
import BinderFormat
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// `move_document` (binder-v0 §6.3, §6.9, §6.10): a filed file moves within the binder with its record, by the
/// filing rules, never over a file; a crash is rolled forward or put back by the digest; Undo moves it back.
/// Invented binders and files only.
@Suite(.serialized) struct MoveDocumentTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])
    static let doc = JSONValue.str("estate-example-doc-2026-010")

    /// A binder with one filed document, `documents/letter.pdf`, and its digest.
    func filed() throws -> (URL, TekaStore, String) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        let intake = folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("an invented letter".utf8).write(to: intake.appendingPathComponent("letter.pdf"))
        let sha = try #require(DocumentPaths.sha256(of: intake.appendingPathComponent("letter.pdf")))
        _ = try store.apply([.init(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", Self.doc), ("title", .str("Invented letter")),
                                          ("path", .str("documents/letter.pdf")), ("sha256", .string(sha))])),
            (key: "from", value: .str("intake/letter.pdf"))]), actor: user)], now: now)
        return (folder, store, sha)
    }

    func move(_ from: String, _ path: String, _ sha: String) -> TekaStore.OpBody {
        .init(op: "move_document", args: JSONObject([(key: "id", value: Self.doc), (key: "from", value: .string(from)),
                                                     (key: "path", value: .string(path)), (key: "sha256", value: .string(sha))]), actor: user)
    }

    func record(_ folder: URL) -> JSONValue? {
        Teka.read(folder).catalog?["documents"]?.arrayValue?.first { $0["id"] == Self.doc }
    }

    func exists(_ folder: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
    }

    @Test func aMoveTakesTheFileAndItsRecordIntoNewFolders() throws {
        let (folder, store, sha) = try filed()
        let before = try #require(record(folder)?.objectValue)
        _ = try store.apply([move("documents/letter.pdf", "letters/2026/letter.pdf", sha)], now: now)
        #expect(!exists(folder, "documents/letter.pdf") && exists(folder, "letters/2026/letter.pdf"))
        var expected = before
        expected.set("path", .str("letters/2026/letter.pdf"))
        #expect(record(folder) == .object(expected))
        _ = try Replay.run(try store.readOpLog().ops)
    }

    @Test func aMoveThatBreaksARuleIsRefusedAndMovesNothing() throws {
        let (folder, store, sha) = try filed()
        try Data("another invented file".utf8).write(to: folder.appendingPathComponent("documents/taken.pdf"))
        let lines = try store.readOpLog().ops.count
        let refused: [TekaStore.OpBody] = [
            move("documents/other.pdf", "letters/letter.pdf", sha),            // not the record's path
            move("documents/letter.pdf", "documents/taken.pdf", sha),          // a file is there
            move("documents/letter.pdf", "documents/Letter.pdf", sha),         // letter case only
            move("documents/letter.pdf", "intake/letter.pdf", sha),            // outside the filing rules
            move("documents/letter.pdf", "keys/id_ed25519", sha),               // a key file's name
            move("documents/letter.pdf", "letters/letter.pdf", String(repeating: "0", count: 64)),   // other bytes
        ]
        for body in refused {
            #expect(throws: (any Error).self, "\(body.args)") { try store.apply([body], now: now) }
        }
        #expect(try store.readOpLog().ops.count == lines)
        #expect(exists(folder, "documents/letter.pdf") && record(folder)?["path"] == .str("documents/letter.pdf"))
    }

    @Test func aFileAnotherRecordNamesStaysWhereItIs() throws {
        let (folder, store, sha) = try filed()
        _ = try store.apply([.init(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", .str("estate-example-doc-2026-011")), ("title", .str("Invented copy")),
                                          ("path", .str("documents/letter.pdf")), ("sha256", .string(sha))]))]), actor: user)], now: now)
        let lines = try store.readOpLog().ops.count
        #expect(throws: TekaStore.Refused.self) { try store.apply([move("documents/letter.pdf", "letters/letter.pdf", sha)], now: now) }
        #expect(try store.readOpLog().ops.count == lines && exists(folder, "documents/letter.pdf"))
    }

    @Test func aRecordNamingTheCatalogNeverMovesIt() throws {
        let catalog = try #require(Teka.read(try filed().0).catalog)
        let op = JSONObject([(key: "id", value: .str("op-1")), (key: "at", value: .str("2026-10-20T09:00:00Z")),
                             (key: "actor", value: .object(user)), (key: "op", value: .str("move_document")),
                             (key: "args", value: .obj([("id", Self.doc), ("from", .str("catalog.json")), ("path", .str("documents/c.json")),
                                                        ("sha256", .string(String(repeating: "a", count: 64)))]))])
        #expect(TransactionGuard.envelopeProblems(op).contains("move_document: from breaks the path rules"))
        #expect(throws: TransactionGuard.Rejection.self) { try TransactionGuard.check([op], on: catalog) }
    }

    @Test func undoMovesTheFileBackWhileTheRecordIsWhereTheMovePutIt() throws {
        let (folder, store, sha) = try filed()
        let moved = try store.apply([move("documents/letter.pdf", "letters/letter.pdf", sha)], now: now)
        try store.undo(opID: moved[0]["id"]!.stringValue!, now: now)
        #expect(exists(folder, "documents/letter.pdf") && !exists(folder, "letters/letter.pdf"))
        #expect(record(folder)?["path"] == .str("documents/letter.pdf"))
        let line = try #require(try store.readOpLog().ops.last)
        #expect(line["compensates"] == moved[0]["id"] && line["expect"] == .obj([("set", .obj([("path", .str("letters/letter.pdf"))]))]))

        // Moved again since: the first move's undo is the person's decision.
        let again = try store.apply([move("documents/letter.pdf", "letters/letter.pdf", sha)], now: now)
        _ = try store.apply([move("letters/letter.pdf", "archive/letter.pdf", sha)], now: now)
        #expect(throws: (any Error).self) { try store.undo(opID: again[0]["id"]!.stringValue!, now: now) }
        #expect(exists(folder, "archive/letter.pdf"))
    }

    @Test func aMoveLoggedButNotMadeIsRolledForward() throws {
        let (folder, store, sha) = try filed()
        struct Crash: Error {}
        store.testHookAfterAppend = { throw Crash() }
        #expect(throws: Crash.self) { try store.apply([move("documents/letter.pdf", "letters/letter.pdf", sha)], now: now) }
        #expect(exists(folder, "documents/letter.pdf"))
        store.testHookAfterAppend = nil
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .rolledForward(1))
        #expect(!exists(folder, "documents/letter.pdf") && exists(folder, "letters/letter.pdf"))
        #expect(record(folder)?["path"] == .str("letters/letter.pdf"))
    }

    @Test func aMoveMadeButNotRecordedIsTakenAsDone() throws {
        let (folder, store, sha) = try filed()
        struct Crash: Error {}
        store.testHookAfterMoves = { throw Crash() }
        #expect(throws: Crash.self) { try store.apply([move("documents/letter.pdf", "letters/letter.pdf", sha)], now: now) }
        #expect(exists(folder, "letters/letter.pdf") && record(folder)?["path"] == .str("documents/letter.pdf"))
        store.testHookAfterMoves = nil
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .rolledForward(1))
        #expect(!exists(folder, "documents/letter.pdf") && record(folder)?["path"] == .str("letters/letter.pdf"))
    }

    @Test func aFailedFolderFlushStopsTheMoveBeforeTheCatalog() throws {
        let (folder, store, sha) = try filed()
        store.testHookFlushFails = { $0 == "flush the folder of a filed file" }
        #expect(throws: AtomicFile.Failure.self) { try store.apply([move("documents/letter.pdf", "letters/letter.pdf", sha)], now: now) }
        #expect(record(folder)?["path"] == .str("documents/letter.pdf"))
        store.testHookFlushFails = nil
        try store.settle(now: now)
        #expect(exists(folder, "letters/letter.pdf") && record(folder)?["path"] == .str("letters/letter.pdf"))
    }
}
