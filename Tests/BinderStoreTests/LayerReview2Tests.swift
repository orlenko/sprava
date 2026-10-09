@testable import BinderStore
import BinderFormat
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the second review of the binder writer (catalog permissions, logged moves outside the binder,
/// failed flushes, concurrent trust records, reopenings with placeholders, overwritten fields of an edited
/// record, and findings that do not name an item). Invented data only.
@Suite(.serialized) struct LayerReview2Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])

    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        return (folder, store)
    }

    func catalog(_ folder: URL) throws -> JSONObject {
        try #require(try JSONParser.parse(try Data(contentsOf: folder.appendingPathComponent("catalog.json"))).value.objectValue)
    }

    func mode(_ url: URL) -> mode_t {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_mode & 0o777 : 0
    }

    func dismiss(_ id: String) -> TekaStore.OpBody {
        .init(op: "dismiss", args: JSONObject([(key: "id", value: .string(id))]), actor: user)
    }

    /// Logs a `file_document` the catalog does not show yet, as a write cut short would leave it.
    func logFiling(_ store: TekaStore, from: String, to path: String, sha: String) throws {
        let (found, hash, _) = try store.readCatalog()
        var line = JSONObject()
        line.set("id", .string(UUIDv7.make(now: now)))
        line.set("at", .str("2026-10-07T09:00:00Z"))
        line.set("actor", .obj([("kind", .str("user")), ("client", .str("invented/1"))]))
        line.set("before_hash", .string(hash))
        line.set("after_hash", .null)
        line.set("op", .str("file_document"))
        line.set("args", .obj([("document", .obj([("id", .str("estate-example-doc-2026-003")), ("title", .str("Invented note")),
                                                  ("path", .string(path)), ("sha256", .string(sha))])),
                               ("from", .string(from))]))
        line.set("after_hash", .string(try Canonical.hash(.object(try OpApplier.apply(line, to: found)))))
        try store.withLock { try store.appendLines([line]) }
    }

    // MARK: - 1. A change never widens the catalog's permissions

    @Test func aChangeKeepsTheCatalogsPermissions() throws {
        let (folder, store) = try adopted()
        let url = folder.appendingPathComponent("catalog.json")
        chmod(url.path, 0o600)
        var tempModes: [mode_t] = []
        store.testHookAfterAppend = {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
            tempModes += names.map { self.mode(folder.appendingPathComponent($0)) }
        }
        try store.apply([dismiss("estate-example-2026-007")], now: now)
        #expect(tempModes == [0o600])
        #expect(mode(url) == 0o600)

        // A catalog others may read stays as it was found.
        chmod(url.path, 0o644)
        try store.apply([dismiss("estate-example-2026-008")], now: now)
        #expect(mode(url) == 0o644)
    }

    // MARK: - 2. A logged move never reaches outside the binder

    @Test func aLoggedMoveOutsideTheBinderIsAborted() throws {
        let (folder, store) = try adopted()
        let root = folder.deletingLastPathComponent()
        let outside = root.appendingPathComponent("outside.txt")
        try Data("invented outside file".utf8).write(to: outside)
        let sha = try #require(DocumentPaths.sha256(of: outside))
        try logFiling(store, from: "../outside.txt", to: "documents/outside.txt", sha: sha)
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .aborted(1))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("documents/outside.txt").path))

        // A traversing destination: the file stays in intake/ and nothing is written beside the binder.
        let intake = folder.appendingPathComponent("intake", isDirectory: true)
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("invented notes".utf8).write(to: intake.appendingPathComponent("notes.txt"))
        let notes = try #require(DocumentPaths.sha256(of: intake.appendingPathComponent("notes.txt")))
        try logFiling(store, from: "intake/notes.txt", to: "../escaped.txt", sha: notes)
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .aborted(1))
        #expect(FileManager.default.fileExists(atPath: intake.appendingPathComponent("notes.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))

        // The move primitive refuses both on its own.
        #expect(throws: TekaStore.Refused.self) { try store.performMoves([("../outside.txt", "documents/outside.txt", sha)]) }
        #expect(throws: TekaStore.Refused.self) { try store.performMoves([("intake/notes.txt", "../escaped.txt", notes)]) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: intake.appendingPathComponent("notes.txt").path))
    }

    // MARK: - 3. A flush that did not reach stable storage fails the write

    @Test func aFailedFullSyncIsNeverTakenForAFlush() throws {
        let (folder, store) = try adopted()
        let before = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        // A disk error from F_FULLFSYNC fails the write, even where plain fsync would succeed.
        store.testHookFullSync = { _ in errno = EIO; return -1 }
        #expect(throws: AtomicFile.Failure.self) { try store.apply([dismiss("estate-example-2026-007")], now: now) }
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == before)
        #expect(try store.readOpLog().ops.count == 1)

        // A volume without F_FULLFSYNC falls back to fsync; an interrupted call is tried again.
        var calls = 0
        store.testHookFullSync = { _ in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            errno = ENOTSUP
            return -1
        }
        try store.apply([dismiss("estate-example-2026-007")], now: now)
        #expect(calls > 2)
        store.testHookFullSync = nil

        // A folder that cannot be flushed fails the write too; the logged change is finished on the next read.
        store.testHookFlushFails = { $0 == "flush the binder folder" }
        #expect(throws: AtomicFile.Failure.self) { try store.apply([dismiss("estate-example-2026-008")], now: now) }
        store.testHookFlushFails = { $0 == "flush the folder of a filed file" }
        let intake = folder.appendingPathComponent("intake", isDirectory: true)
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: intake.appendingPathComponent("letter.pdf"))
        let sha = try #require(DocumentPaths.sha256(of: intake.appendingPathComponent("letter.pdf")))
        let filing = TekaStore.OpBody(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", .str("estate-example-doc-2026-003")), ("title", .str("Invented letter")),
                                          ("path", .str("documents/letter.pdf")), ("sha256", .string(sha))])),
            (key: "from", value: .str("intake/letter.pdf"))]), actor: user)
        #expect(throws: AtomicFile.Failure.self) { try store.apply([filing], now: now) }
        #expect(!(try catalog(folder)["documents"]?.arrayValue ?? []).contains { $0["path"] == .str("documents/letter.pdf") })
        store.testHookFlushFails = nil
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .rolledForward(1))
        #expect((try catalog(folder)["documents"]?.arrayValue ?? []).contains { $0["path"] == .str("documents/letter.pdf") })
    }

    // MARK: - 4. Concurrent trust records keep every card

    @Test func concurrentTrustRecordsKeepEveryCard() throws {
        let c = Commands(support: FileManager.default.temporaryDirectory.appendingPathComponent("sprava-review2-\(UUID().uuidString)"),
                         deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        var ids: [String] = []
        for n in 1...16 {
            let card = Proposal.make(title: "Invented card \(n)", actor: user, ops: [], now: now)
            try ProposalStore.save(card, in: folder)
            ids.append(card.id)
        }
        let cards = ids
        DispatchQueue.concurrentPerform(iterations: cards.count) { i in
            if i.isMultiple(of: 2) {
                try? c.trustProposals([cards[i]], in: folder)
            } else if let listed = ProposalStore.list(in: folder).first(where: { $0.0.id == cards[i] }) {
                try? c.trustChecked(cards[i], digest: listed.1, in: folder)
            }
        }
        #expect(cards.allSatisfy { c.isTrusted($0, in: folder) })
    }

    // MARK: - 5. A reopening's placeholder is minted

    @Test func aReopeningGetsANewID() throws {
        let catalog = try #require(try JSONParser.parse(#"""
            {"meta":{"name":"example"},"open_items":[],"processing_log":[{"id":"example-2026-001","title":"Invented","action":"done"}]}
            """#).value.objectValue)
        let at = "2026-10-07T09:00:00Z"
        let ops = [
            JSONObject([(key: "op", value: .str("reopen")),
                        (key: "args", value: .obj([("id", .str("example-2026-001")),
                                                   ("item", .obj([("id", .str("$new:1")), ("title", .str("Invented"))]))]))]),
            JSONObject([(key: "op", value: .str("update_item")),
                        (key: "args", value: .obj([("id", .str("$new:1")), ("set", .obj([("priority", .str("high"))]))]))]),
        ]
        let resolved = try Placeholders.resolve(ops, catalog: catalog, opLog: [], year: 2026, at: at)
        #expect(resolved[0]["args"]?["id"] == .str("example-2026-001"))
        #expect(resolved[0]["args"]?["item"]?["id"] == .str("example-2026-002"))
        #expect(resolved[0]["args"]?["item"]?["created_at"] == .string(at))
        #expect(resolved[0]["args"]?["item"]?["updated_at"] == .string(at))
        #expect(resolved[1]["args"]?["id"] == .str("example-2026-002"))

        // A placeholder that reaches the guard unminted is refused, never written as an id.
        var line = ops[0]
        line.set("actor", .object(user))
        #expect(TransactionGuard.envelopeProblems(line).contains { $0.contains("placeholder") })
    }

    // MARK: - 6. An edit of another field of the same record does not hide an overwritten change

    @Test func anOverwrittenFieldIsFoundBesideAnotherEdit() throws {
        let (folder, store) = try adopted()
        let url = folder.appendingPathComponent("catalog.json")
        let found = try Data(contentsOf: url)
        let raise = TekaStore.OpBody(op: "update_item", args: JSONObject([
            (key: "id", value: .str("estate-example-2026-008")), (key: "set", value: .obj([("priority", .str("high"))]))]), actor: user)
        try store.apply([raise], now: now)

        // An editor that read the catalog before the change retitles the same item and saves its whole copy.
        func retitle(_ data: Data, _ title: String) throws {
            var c = try #require(try JSONParser.parse(data).value.objectValue)
            var items = c["open_items"]?.arrayValue ?? []
            let index = try #require(items.firstIndex { $0["id"] == .str("estate-example-2026-008") })
            var item = try #require(items[index].objectValue)
            item.set("title", .string(title))
            items[index] = .object(item)
            c.set("open_items", .array(items))
            try Data(JSONWriter.pretty(.object(c)).utf8).write(to: url)
        }
        try retitle(found, "Invented statement, retitled by hand")
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .externalEdit(revertedLastBatch: true))

        // The same retitle on top of the change keeps it: nothing was lost.
        try store.apply([raise], now: now)
        try retitle(try Data(contentsOf: url), "Invented statement, retitled again")
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .externalEdit(revertedLastBatch: false))
    }

    // MARK: - 7. Only a strictly written open_items[<digits>] finding is an item's violation

    @Test func onlyAStrictItemLocationNamesAnItem() throws {
        #expect(TransactionGuard.itemIndex("open_items[0]") == 0)
        #expect(TransactionGuard.itemIndex("open_items[12]") == 12)
        for location in ["documents[0]", "open_items[+0]", "open_items[0", "open_items[]", "open_items[ 1]",
                         "open_items[\u{0661}]", "processing_log[0]"] {
            #expect(TransactionGuard.itemIndex(location) == nil)
        }
        let items: [JSONValue] = [.obj([("id", .str("estate-example-2026-001")), ("title", .str("Invented item"))])]
        let violations = TransactionGuard.itemViolations([(.badPath, "documents[0]", "path"),
                                                          (.badDue, "open_items[0]", "due")], items: items)
        // The document's finding stays with the document; only the item's own finding names the item.
        #expect(violations == [Violation(array: "documents", recordKey: "documents[0]", rule: "bad-path:path"),
                               Violation(array: "open_items", recordKey: "estate-example-2026-001", rule: "bad-due:due")])
    }
}
