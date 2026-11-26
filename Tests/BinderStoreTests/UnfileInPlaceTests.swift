@testable import BinderStore
import BinderFormat
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// `unfile_document` in place, and the undo of a filing recorded where the file already was (binder-v0 §6.3, §6.10):
/// the record goes, the op keeps it, the file stays where it is, and the id is never minted again. Returning a file to
/// intake/ is not applied, since this version keeps no intake hold. Invented binders and files only.
@Suite(.serialized) struct UnfileInPlaceTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])
    let path = "summaries/summary.md"

    /// A binder with a file written in it and then filed where it is. Returns the filing's op id and the record.
    func filedInPlace() throws -> (folder: URL, store: TekaStore, op: String, record: JSONObject) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("An invented summary".utf8).write(to: url)
        let sha = try #require(DocumentPaths.sha256(of: url))
        let lines = try store.applyMinting([.init(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", .str("$new:1")), ("title", .str("Invented summary")), ("path", .string(path)), ("sha256", .string(sha))]))]),
            actor: user)], now: now)
        let op = try #require(lines.first?["id"]?.stringValue)
        let record = try #require(documents(folder).first { $0["path"] == .string(path) })
        return (folder, store, op, record)
    }

    func documents(_ folder: URL) -> [JSONObject] { Teka.read(folder).catalog?["documents"]?.arrayValue?.compactMap(\.objectValue) ?? [] }
    func exists(_ folder: URL) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) }
    func unfile(_ record: JSONObject, _ change: (inout JSONObject) -> Void = { _ in }) -> JSONObject {
        var args = JSONObject([(key: "id", value: record["id"] ?? .null), (key: "from", value: record["path"] ?? .null),
                               (key: "sha256", value: record["sha256"] ?? .null), (key: "document", value: .object(record))])
        change(&args)
        return args
    }
    /// The error `body` throws, as text; a test fails when it throws nothing.
    func refusal(_ body: () throws -> Void) -> String {
        do { try body() } catch { return "\(error)" }
        Issue.record("nothing was refused")
        return ""
    }

    @Test func undoingAFilingInPlaceRemovesTheRecordAndLeavesTheFile() throws {
        let (folder, store, op, record) = try filedInPlace()
        #expect(Undo.supported(try #require(try store.readOpLog().ops.first { $0["id"]?.stringValue == op })))
        _ = try store.undoChange(opID: op, now: now)
        #expect(documents(folder).allSatisfy { $0["id"] != record["id"] })
        #expect(exists(folder))
        // The op keeps the whole record and names what it undoes.
        let line = try #require(try store.readOpLog().ops.last)
        #expect(line["op"] == .str("unfile_document") && line["compensates"] == .string(op) && line["args"]?["document"] == .object(record))
        #expect(line["args"]?["to"] == nil)
        // Replaying the log reaches the catalog on disk.
        #expect(try Canonical.hash(.object(try Replay.run(try store.readOpLog().ops))) == line["after_hash"]?.stringValue)
        #expect(refusal { _ = try store.undoChange(opID: op, now: now) }.contains("already undone"))
        #expect(Teka.read(folder).reasons.isEmpty)
    }

    @Test func theIdOfAnUnfiledDocumentIsNeverMintedAgain() throws {
        let (folder, store, op, record) = try filedInPlace()
        _ = try store.undoChange(opID: op, now: now)
        let sha = try #require(DocumentPaths.sha256(of: folder.appendingPathComponent(path)))
        _ = try store.applyMinting([.init(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", .str("$new:1")), ("title", .str("Invented summary")), ("path", .string(path)), ("sha256", .string(sha))]))]),
            actor: user)], now: now)
        let again = try #require(documents(folder).first { $0["path"] == .string(path) })
        #expect(again["id"] != record["id"])
    }

    @Test func aFilingThatTookTheFileFromIntakeIsNotOfferedAnUndo() throws {
        let (folder, store, _, _) = try filedInPlace()
        let intake = folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("an invented letter".utf8).write(to: intake.appendingPathComponent("letter.pdf"))
        let sha = try #require(DocumentPaths.sha256(of: intake.appendingPathComponent("letter.pdf")))
        let lines = try store.apply([.init(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", .str("estate-example-doc-2026-010")), ("title", .str("Invented letter")), ("path", .str("documents/letter.pdf")), ("sha256", .string(sha))])),
            (key: "from", value: .str("intake/letter.pdf"))]), actor: user)], now: now)
        let line = try #require(lines.first), op = try #require(line["id"]?.stringValue)
        #expect(!Undo.supported(line))
        #expect(refusal { _ = try store.undoChange(opID: op, now: now) }.contains("intake/"))
        #expect(documents(folder).contains { $0["path"] == .str("documents/letter.pdf") })
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("documents/letter.pdf").path))
    }

    @Test func aRecordOrFileChangedSinceTheFilingKeepsItsRecord() throws {
        // The record was corrected since: that is undone first, or the record corrected by hand.
        let (folder, store, op, record) = try filedInPlace()
        let edit = try store.apply([.init(op: "update_document", args: JSONObject([(key: "id", value: record["id"] ?? .null),
            (key: "set", value: .obj([("title", .str("The person's own title"))]))]), actor: user)], now: now)
        #expect(refusal { _ = try store.undoChange(opID: op, now: now) }.contains("changed since"))
        #expect(documents(folder).contains { $0["title"] == .str("The person's own title") })
        // With the correction undone, the filing can be.
        _ = try store.undoChange(opID: try #require(edit.first?["id"]?.stringValue), now: now)
        _ = try store.undoChange(opID: op, now: now)
        #expect(documents(folder).allSatisfy { $0["id"] != record["id"] } && exists(folder))

        // The file was edited since: the record no longer describes it, and is corrected, not removed.
        let (other, second, filing, kept) = try filedInPlace()
        try Data("An invented summary, edited".utf8).write(to: other.appendingPathComponent(path))
        #expect(refusal { _ = try second.undoChange(opID: filing, now: now) }.contains("changed or is gone"))
        #expect(documents(other).contains { $0["id"] == kept["id"] })
        // And a file that is gone.
        try FileManager.default.removeItem(at: other.appendingPathComponent(path))
        #expect(refusal { _ = try second.undoChange(opID: filing, now: now) }.contains("changed or is gone"))
        #expect(documents(other).contains { $0["id"] == kept["id"] })
    }

    @Test func theGuardHoldsTheOpToTheRecordAsItIsAndToThePerson() throws {
        let (folder, store, _, record) = try filedInPlace()
        let count = try store.readOpLog().ops.count
        let brain = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("sprava/0.1")), (key: "model", value: .str("invented"))])
        let conversation: [(String, JSONValue)] = [("approved_by", .str("user")), ("conversation", .obj([("turn", .str("t")), ("message", .str("m"))]))]
        var stale = record; stale.set("title", .str("Another title"))
        let bad: [(String, TekaStore.OpBody)] = [
            ("a model's op", .init(op: "unfile_document", args: unfile(record), actor: brain, extra: conversation)),
            ("to intake/", .init(op: "unfile_document", args: unfile(record) { $0.set("to", .str("intake/summary.md")) }, actor: user)),
            ("another record's text", .init(op: "unfile_document", args: unfile(record) { $0.set("document", .object(stale)) }, actor: user)),
            ("another path", .init(op: "unfile_document", args: unfile(record) { $0.set("from", .str("summaries/other.md")) }, actor: user)),
            ("another digest", .init(op: "unfile_document", args: unfile(record) { $0.set("sha256", .string(String(repeating: "0", count: 64))) }, actor: user)),
            ("no record kept", .init(op: "unfile_document", args: unfile(record) { $0.remove("document") }, actor: user)),
            ("no such document", .init(op: "unfile_document", args: unfile(record) { $0.set("id", .str("estate-example-doc-2026-999")) }, actor: user)),
            ("a path outside", .init(op: "unfile_document", args: unfile(record) { $0.set("from", .str("../outside.md")) }, actor: user)),
        ]
        for (what, body) in bad {
            #expect(!refusal { _ = try store.apply([body], now: now) }.isEmpty, "\(what)")
        }
        #expect(try store.readOpLog().ops.count == count)
        #expect(documents(folder).contains { $0 == record } && exists(folder))
        // The op as it should be, by the person, applies.
        _ = try store.apply([.init(op: "unfile_document", args: unfile(record), actor: user)], now: now)
        #expect(documents(folder).allSatisfy { $0["id"] != record["id"] } && exists(folder))
    }
}
