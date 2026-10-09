@testable import BinderStore
import BinderFormat
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from Codex Bugbot's review of the binder writer (PR #9): an op log a newer version wrote, a stamp
/// repair to the wrong version, an oversized catalog, an edit made while files are moved, a recorded path in another
/// case, and the time a card finished after a crash was applied. Invented data only.
@Suite(.serialized) struct BugbotPR9Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])

    func adopted(_ mutate: ((URL) throws -> Void)? = nil) throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0", mutate: mutate)
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        return (folder, store)
    }

    func catalogData(_ folder: URL) throws -> Data { try Data(contentsOf: folder.appendingPathComponent("catalog.json")) }

    func catalog(_ folder: URL) throws -> JSONObject {
        try #require(try JSONParser.parse(try catalogData(folder)).value.objectValue)
    }

    func write(_ c: JSONObject, to folder: URL) throws {
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: folder.appendingPathComponent("catalog.json"))
    }

    func exists(_ folder: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
    }

    func dismiss(_ id: String) -> TekaStore.OpBody {
        .init(op: "dismiss", args: JSONObject([(key: "id", value: .string(id))]), actor: user)
    }

    func intakeFile(_ folder: URL, _ name: String, _ text: String) throws -> String {
        let intake = folder.appendingPathComponent("intake", isDirectory: true)
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: intake.appendingPathComponent(name))
        return try #require(DocumentPaths.sha256(of: intake.appendingPathComponent(name)))
    }

    func filing(_ from: String, to path: String, sha: String) -> TekaStore.OpBody {
        .init(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", .str("estate-example-doc-2026-003")), ("title", .str("Invented letter")),
                                          ("path", .string(path)), ("sha256", .string(sha))])),
            (key: "from", value: .string(from)),
        ]), actor: user)
    }

    /// Another program's edit: the first item's priority set by hand.
    func editByHand(_ folder: URL) throws {
        var c = try catalog(folder)
        var items = c["open_items"]?.arrayValue ?? []
        var first = try #require(items.first?.objectValue)
        first.set("priority", .str("low"))
        items[0] = .object(first)
        c.set("open_items", .array(items))
        try write(c, to: folder)
    }

    // MARK: - An op type this version does not know stops every write

    @Test func anOpLogFromANewerVersionIsNeverAppendedTo() throws {
        let (folder, store) = try adopted()
        let (_, hash, _) = try store.readCatalog()
        var line = JSONObject()
        line.set("id", .string(UUIDv7.make(now: now)))
        line.set("at", .str("2026-10-07T09:00:00Z"))
        line.set("actor", .obj([("kind", .str("user")), ("client", .str("invented/2"))]))
        line.set("before_hash", .string(hash))
        line.set("after_hash", .string(hash))
        line.set("op", .str("invented_future_op"))
        line.set("args", .obj([]))
        try store.withLock { try store.appendLines([line]) }
        let log = try Data(contentsOf: folder.appendingPathComponent(".sprava/ops.ndjson"))
        let before = try catalogData(folder)

        #expect(throws: TekaStore.Refused.self) { try store.apply([dismiss("estate-example-2026-007")], now: now) }
        // Not even an outside edit is recorded.
        try editByHand(folder)
        let edited = try catalogData(folder)
        #expect(throws: TekaStore.Refused.self) { try store.settle(now: now) }
        #expect(try Data(contentsOf: folder.appendingPathComponent(".sprava/ops.ndjson")) == log)
        #expect(try catalogData(folder) == edited && edited != before)
    }

    // MARK: - A stamp repair must leave a stamp this version reads

    @Test func aStampRepairToAnotherVersionIsRefused() throws {
        let (folder, store) = try adopted { folder in
            let url = folder.appendingPathComponent("catalog.json")
            var c = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
            var meta = try #require(c["meta"]?.objectValue)
            meta.set("format_version", .str("zero"))
            c.set("meta", .object(meta))
            try Data(JSONWriter.pretty(.object(c)).utf8).write(to: url)
        }
        #expect(CatalogLevel.classify(try catalog(folder)) == .brokenStamp)
        let importActor = JSONObject([(key: "kind", value: .str("import")), (key: "client", value: .str("sprava/0.1"))])
        func repair(_ value: String) -> TekaStore.OpBody {
            .init(op: "migrate", args: JSONObject([(key: "patch", value: .array([
                .obj([("op", .str("replace")), ("path", .str("/meta/format_version")), ("value", .string(value))]),
            ]))]), actor: importActor)
        }
        let before = try catalogData(folder)
        let opCount = try store.readOpLog().ops.count
        // A newer version's stamp would leave a catalog every later write refuses; a non-digit one stays broken.
        for bad in ["1", "0x"] {
            #expect(throws: TekaStore.Refused.self) { try store.apply([repair(bad)], now: now) }
        }
        #expect(try catalogData(folder) == before)
        #expect(try store.readOpLog().ops.count == opCount)

        try store.apply([repair("0")], now: now)
        #expect(CatalogLevel.classify(try catalog(folder)) == .tekaV0)
        try store.apply([dismiss("estate-example-2026-007")], now: now)
    }

    // MARK: - A catalog larger than the reader's limit is refused before it is read

    @Test func anOversizedCatalogIsRefusedUnread() throws {
        let (folder, store) = try adopted()
        let url = folder.appendingPathComponent("catalog.json")
        // A sparse file: its length is past the limit, its blocks are not written.
        #expect(truncate(url.path, off_t(TekaStore.maxCatalogBytes + 1)) == 0)
        #expect(throws: TekaStore.Refused.self) { try store.settle(now: now) }
        #expect(throws: TekaStore.Refused.self) { try store.apply([dismiss("estate-example-2026-007")], now: now) }
        #expect(try store.readOpLog().ops.count == 1)
    }

    // MARK: - An edit made while files are moved is never written over

    @Test func anEditMadeWhileFilesAreMovedIsKept() throws {
        let (folder, store) = try adopted()
        let sha = try intakeFile(folder, "letter.pdf", "invented letter")
        var edits = 0
        store.testHookAfterMoves = {
            guard edits == 0 else { return }
            edits += 1
            try self.editByHand(folder)
        }
        try store.apply([filing("intake/letter.pdf", to: "documents/2026-10-07_letter.pdf", sha: sha)], now: now)
        #expect(edits == 1)

        // The edit is there, and so is the filing, applied again on top of it.
        let c = try catalog(folder)
        #expect(c["open_items"]?.arrayValue?.first?["priority"] == .str("low"))
        #expect(c["documents"]?.arrayValue?.contains { $0["path"] == .str("documents/2026-10-07_letter.pdf") } == true)
        #expect(exists(folder, "documents/2026-10-07_letter.pdf") && !exists(folder, "intake/letter.pdf"))
        let ops = try store.readOpLog().ops
        #expect(ops.filter { $0["op"] == .str("abort") }.count == 1)
        #expect(ops.filter { $0["op"] == .str("external_edit") }.count == 1)
        #expect(ops.filter { $0["op"] == .str("file_document") }.count == 2)
        #expect(ops.last?["after_hash"]?.stringValue == (try store.readCatalog()).1)
    }

    // MARK: - A filed file the found catalog records in another case stays where it is

    @Test func aFileRecordedInAnotherCaseIsNotMovedBack() throws {
        let (folder, store) = try adopted()
        let probe = folder.appendingPathComponent("case-probe")
        try Data().write(to: probe)
        // Only a volume that folds case names one file both ways.
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("CASE-PROBE").path) else { return }
        try FileManager.default.removeItem(at: probe)

        let catalogBefore = try catalogData(folder)
        let snapshotBefore = try Data(contentsOf: folder.appendingPathComponent(".sprava/snapshot.json"))
        let sha = try intakeFile(folder, "letter.pdf", "invented letter")
        try store.apply([filing("intake/letter.pdf", to: "documents/2026-10-07_letter.pdf", sha: sha)], now: now)
        // A crash after the move and before the rename; then an editor records the moved file, spelled in another case.
        try snapshotBefore.write(to: folder.appendingPathComponent(".sprava/snapshot.json"))
        var c = try #require(try JSONParser.parse(catalogBefore).value.objectValue)
        var docs = c["documents"]?.arrayValue ?? []
        docs.append(.obj([("id", .str("estate-example-doc-2026-009")), ("title", .str("Invented letter, recorded by hand")),
                          ("path", .str("Documents/2026-10-07_Letter.pdf"))]))
        c.set("documents", .array(docs))
        try write(c, to: folder)

        try store.settle(now: now)
        #expect(!exists(folder, "intake/letter.pdf"))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("documents").path)
        #expect(names == ["2026-10-07_letter.pdf"])
    }

    // MARK: - An approved adoption card that another program overwrote is offered again

    @Test func anOverwrittenAdoptionCardIsOfferedAgain() throws {
        let (folder, store) = try adopted()
        let found = try catalogData(folder)
        // A repair card of adoption (actor import), approved by the person with the date they typed.
        let importActor = JSONObject([(key: "kind", value: .str("import")), (key: "client", value: .str("sprava/0.1"))])
        let op = JSONObject([(key: "op", value: .str("update_item")),
                             (key: "args", value: .obj([("id", .str("estate-example-2026-007")), ("set", .obj([("due", .str("2026-11-20"))]))]))])
        let card = Proposal.make(title: "Fill in what this item is missing", actor: importActor, ops: [op], now: now)
        try ProposalStore.save(card, in: folder)
        let applied = try store.approve(card, now: now)
        // Another program that read the catalog before the approval writes its copy back, with a change of its own.
        var c = try #require(try JSONParser.parse(found).value.objectValue)
        var items = c["open_items"]?.arrayValue ?? []
        var second = try #require(items[1].objectValue)
        second.set("priority", .str("low"))
        items[1] = .object(second)
        c.set("open_items", .array(items))
        try write(c, to: folder)

        try store.settle(now: now)
        #expect(store.lastAbsorbed == .externalEdit(revertedLastBatch: true))
        let offered = ProposalStore.list(in: folder).map(\.0).filter {
            $0.raw["provenance"]?["overwritten_ops"] == .array(applied.compactMap { $0["id"] })
        }
        #expect(offered.count == 1)
        #expect(offered.first?.ops.first?["args"]?["set"]?["due"] == .str("2026-11-20"))
        #expect(offered.first?.raw["provenance"]?["manual_repair"] == nil)
    }

    // MARK: - A card finished after a crash records when it was applied

    @Test func aCardMarkedAfterACrashRecordsWhenItWasApplied() throws {
        let (folder, store) = try adopted()
        let op = JSONObject([(key: "op", value: .str("dismiss")), (key: "args", value: .obj([("id", .str("estate-example-2026-007"))]))])
        let card = Proposal.make(title: "Invented card", actor: user, ops: [op], now: now)
        try ProposalStore.save(card, in: folder)
        let lines = try store.approve(card, now: now)
        // A crash after the batch was written and before the card was marked: the card is still proposed.
        try ProposalStore.save(card, in: folder)
        let later = now.addingTimeInterval(3600)
        let again = try store.approve(card, now: later)
        #expect(again.map { $0["id"] } == lines.map { $0["id"] })
        let marked = try ProposalStore.load(card.id, in: folder, expectedDigest: nil)
        #expect(marked.state == "applied")
        #expect(marked.raw["applied_at"] == lines.first?["at"])
        #expect(marked.raw["applied_ops"] == .array(lines.compactMap { $0["id"] }))
    }
}
