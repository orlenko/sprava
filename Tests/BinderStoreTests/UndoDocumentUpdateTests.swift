@testable import BinderStore
import BinderFormat
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// The undo of `update_document` (binder-v0 §6.10): the same op, restoring the earlier values field by field. A field
/// changed since keeps its newer value; the undo is refused where it would loosen privacy behind a later change or
/// leave a record without a title or a path. Invented binders and files only.
@Suite(.serialized) struct UndoDocumentUpdateTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])
    static let doc = JSONValue.str("estate-example-doc-2026-010")

    /// A binder with one filed document, `documents/letter.pdf`, dated and of a kind.
    func filed() throws -> (URL, TekaStore, String) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        let intake = folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("an invented letter".utf8).write(to: intake.appendingPathComponent("letter.pdf"))
        let sha = try #require(DocumentPaths.sha256(of: intake.appendingPathComponent("letter.pdf")))
        _ = try store.apply([.init(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", Self.doc), ("title", .str("Invented letter")), ("path", .str("documents/letter.pdf")),
                                          ("sha256", .string(sha)), ("date", .str("2026-03-01")), ("kind", .str("letter"))])),
            (key: "from", value: .str("intake/letter.pdf"))]), actor: user)], now: now)
        return (folder, store, sha)
    }

    func update(_ store: TekaStore, set: [(String, JSONValue)] = [], unset: [String] = []) throws -> String {
        var args = JSONObject([(key: "id", value: Self.doc)])
        if !set.isEmpty { args.set("set", .obj(set)) }
        if !unset.isEmpty { args.set("unset", .array(unset.map(JSONValue.string))) }
        let lines = try store.apply([.init(op: "update_document", args: args, actor: user)], now: now)
        return try #require(lines.first?["id"]?.stringValue)
    }

    func record(_ folder: URL) -> JSONObject? {
        Teka.read(folder).catalog?["documents"]?.arrayValue?.first { $0["id"] == Self.doc }?.objectValue
    }

    /// The error `body` throws, as text; a test fails when it throws nothing.
    func refusal(_ body: () throws -> Void) -> String {
        do { try body() } catch { return "\(error)" }
        Issue.record("nothing was refused")
        return ""
    }

    @Test func anUndoPutsBackWhatChangedAndRemovesWhatWasAdded() throws {
        let (folder, store, _) = try filed()
        let original = try #require(record(folder))
        let op = try update(store, set: [("title", .str("Invented notice")), ("date", .str("2026-04-02")), ("source", .str("a scan"))], unset: ["kind"])
        #expect(record(folder)?["kind"] == nil && record(folder)?["source"] == .str("a scan"))

        let outcome = try store.undoChange(opID: op, now: now)
        #expect(outcome.kept.isEmpty)
        #expect(record(folder) == original)
        let line = try #require(try store.readOpLog().ops.last)
        #expect(line["op"] == .str("update_document") && line["compensates"] == .string(op))
        #expect(line["args"]?["unset"] == .array([.str("source")]))
        #expect(line["expect"] == .obj([("set", .obj([("title", .str("Invented notice")), ("date", .str("2026-04-02")), ("source", .str("a scan"))])),
                                        ("absent", .array([.str("kind")]))]))
        #expect(refusal { try store.undoChange(opID: op, now: now) }.contains("already undone"))
        _ = try Replay.run(try store.readOpLog().ops)
    }

    @Test func theChangeListOffersUndoForIt() throws {
        #expect(Undo.supported(JSONObject([(key: "op", value: .str("update_document"))])))
    }

    @Test func aFieldChangedSinceKeepsItsNewerValue() throws {
        let (folder, store, _) = try filed()
        let op = try update(store, set: [("title", .str("Invented notice")), ("date", .str("2026-04-02"))])
        _ = try update(store, set: [("title", .str("Invented final notice"))])   // the person's later change

        let outcome = try store.undoChange(opID: op, now: now)
        #expect(outcome.kept == ["title"])
        #expect(record(folder)?["title"] == .str("Invented final notice"))
        #expect(record(folder)?["date"] == .str("2026-03-01"))
    }

    @Test func aFieldSetBackToTheUndoneValueSinceKeepsTheLaterChoice() throws {
        let (folder, store, _) = try filed()
        let op = try update(store, set: [("title", .str("Invented notice"))])
        _ = try update(store, set: [("title", .str("Something else"))])
        _ = try update(store, set: [("title", .str("Invented notice"))])   // chosen again, so it is the later choice

        #expect(refusal { try store.undoChange(opID: op, now: now) }.contains("title changed since"))
        #expect(record(folder)?["title"] == .str("Invented notice"))
    }

    // Restored content never meets a looser privacy state than it had (architecture 4.5).
    @Test func anUndoBehindALaterChangeNeverTouchesSensitivity() throws {
        let (folder, store, _) = try filed()
        let marked = try update(store, set: [("sensitivity", .str("private")), ("title", .str("Invented notice"))])
        _ = try update(store, set: [("date", .str("2026-05-05"))])
        #expect(refusal { try store.undoChange(opID: marked, now: now) }.contains("sensitivity"))
        #expect(record(folder)?["sensitivity"] == .str("private") && record(folder)?["title"] == .str("Invented notice"))

        // A title edit made before the marker changed is refused too: the title would come back under another marker.
        let (other, second, _) = try filed()
        let titled = try update(second, set: [("title", .str("Invented notice"))])
        _ = try update(second, set: [("sensitivity", .str("private"))])
        #expect(refusal { try second.undoChange(opID: titled, now: now) }.contains("sensitivity"))
        #expect(record(other)?["title"] == .str("Invented notice"))

        // With nothing changed since, the person's Undo puts the marker back as it was.
        let (third, last, _) = try filed()
        let only = try update(last, set: [("sensitivity", .str("private"))])
        _ = try last.undoChange(opID: only, now: now)
        #expect(record(third)?["sensitivity"] == nil)
    }

    // `update_document` with a path records that the file was moved outside Sprava. Its undo records the old path
    // again, which holds only once the file is back there.
    @Test func aRestoredPathNeedsItsFile() throws {
        let (folder, store, _) = try filed()
        let manager = FileManager.default
        let old = folder.appendingPathComponent("documents/letter.pdf"), new = folder.appendingPathComponent("documents/moved.pdf")
        try manager.moveItem(at: old, to: new)
        let op = try update(store, set: [("path", .str("documents/moved.pdf"))])

        #expect(refusal { try store.undoChange(opID: op, now: now) }.contains("no file is at documents/letter.pdf"))
        #expect(record(folder)?["path"] == .str("documents/moved.pdf"))
        try manager.moveItem(at: new, to: old)
        _ = try store.undoChange(opID: op, now: now)
        #expect(record(folder)?["path"] == .str("documents/letter.pdf"))
    }

    // A move writes the record's path, so a path recorded before it is the earlier choice even when the document is
    // moved back to the same place.
    @Test func aMoveSinceCountsAsAChangeOfPath() throws {
        let (folder, store, sha) = try filed()
        let manager = FileManager.default
        try manager.moveItem(at: folder.appendingPathComponent("documents/letter.pdf"), to: folder.appendingPathComponent("documents/moved.pdf"))
        let op = try update(store, set: [("path", .str("documents/moved.pdf")), ("title", .str("Invented notice"))])
        func move(_ from: String, _ to: String) throws {
            _ = try store.apply([.init(op: "move_document", args: JSONObject([(key: "id", value: Self.doc), (key: "from", value: .string(from)),
                (key: "path", value: .string(to)), (key: "sha256", value: .string(sha))]), actor: user)], now: now)
        }
        try move("documents/moved.pdf", "letters/letter.pdf")
        try move("letters/letter.pdf", "documents/moved.pdf")

        let outcome = try store.undoChange(opID: op, now: now)
        #expect(outcome.kept == ["path"])
        #expect(record(folder)?["path"] == .str("documents/moved.pdf") && record(folder)?["title"] == .str("Invented letter"))
    }

    // The cases no applied op of a v0 writer produces, straight through the compensation: a record found with no
    // title that an update titled, and an update that changed nothing.
    @Test func anUndoNeverLeavesARecordWithoutATitleOrChangesNothing() throws {
        func catalog(_ document: [(String, JSONValue)]) -> JSONObject {
            JSONObject([(key: "documents", value: .array([.obj([("id", Self.doc), ("path", .str("documents/letter.pdf"))] + document)]))])
        }
        func target(_ set: [(String, JSONValue)]) -> JSONObject {
            JSONObject([(key: "id", value: .str("op-1")), (key: "op", value: .str("update_document")),
                        (key: "args", value: .obj([("id", Self.doc), ("set", .obj(set))]))])
        }
        let titled = target([("title", .str("letter"))])
        let untitled = refusal {
            _ = try Undo.compensation(titled, catalog: catalog([("title", .str("letter"))]), opLog: [titled], stateBefore: catalog([]),
                                      stateAfter: catalog([("title", .str("letter"))]), year: 2026, now: now)
        }
        #expect(untitled.contains("had no title before this change"))

        let same = target([("title", .str("letter"))])
        let nothing = refusal {
            _ = try Undo.compensation(same, catalog: catalog([("title", .str("letter"))]), opLog: [same],
                                      stateBefore: catalog([("title", .str("letter"))]), stateAfter: catalog([("title", .str("letter"))]),
                                      year: 2026, now: now)
        }
        #expect(nothing.contains("nothing to undo"))

        let gone = refusal {
            _ = try Undo.compensation(same, catalog: JSONObject([(key: "documents", value: .array([]))]), opLog: [same],
                                      stateBefore: catalog([("title", .str("old"))]), stateAfter: catalog([("title", .str("letter"))]),
                                      year: 2026, now: now)
        }
        #expect(gone.contains("no longer in the catalog"))
    }
}
