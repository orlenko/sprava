@testable import BinderStore
import BinderFormat
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the review of the binder writer (trust taken from the bytes written, approvals that race,
/// several ops without a batch, filings stranded by recovery, document paths, key files, failed flushes and
/// recovery cards that could not be saved). Invented data only.
@Suite(.serialized) struct StackReviewTests {
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

    func exists(_ folder: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
    }

    /// An invented file dropped into intake/; returns its digest.
    func intakeFile(_ folder: URL, _ name: String, _ text: String) throws -> String {
        let intake = folder.appendingPathComponent("intake", isDirectory: true)
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: intake.appendingPathComponent(name))
        return try #require(DocumentPaths.sha256(of: intake.appendingPathComponent(name)))
    }

    func filing(_ from: String?, to path: String, sha: String, id: String = "estate-example-doc-2026-003") -> TekaStore.OpBody {
        var args = JSONObject([(key: "document", value: .obj([("id", .string(id)), ("title", .str("Invented letter")),
                                                             ("path", .string(path)), ("sha256", .string(sha))]))])
        if let from { args.set("from", .string(from)) }
        return .init(op: "file_document", args: args, actor: user)
    }

    func dismiss(_ id: String) -> TekaStore.OpBody {
        .init(op: "dismiss", args: JSONObject([(key: "id", value: .string(id))]), actor: user)
    }

    /// Another program's edit of the catalog: the first item's priority set by hand.
    func editByHand(_ folder: URL, from data: Data) throws {
        var c = try #require(try JSONParser.parse(data).value.objectValue)
        var items = c["open_items"]?.arrayValue ?? []
        var first = try #require(items.first?.objectValue)
        first.set("priority", .str("low"))
        items[0] = .object(first)
        c.set("open_items", .array(items))
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: folder.appendingPathComponent("catalog.json"))
    }

    // MARK: - 1. Trust comes from the bytes Sprava wrote, never from a read afterwards

    @Test func aCardReplacedBeforeItIsTrustedStaysUntrusted() throws {
        let c = Commands(support: FileManager.default.temporaryDirectory.appendingPathComponent("sprava-review-\(UUID().uuidString)"),
                         deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        let card = Proposal.make(title: "Invented card", actor: user, ops: [], now: now)
        try ProposalStore.save(card, in: folder)
        // Another program writes over the card between the save and the record of its digest.
        var raw = card.raw
        raw.set("title", .str("Invented card, rewritten outside"))
        try Data(JSONWriter.pretty(.object(raw)).utf8).write(to: ProposalStore.dir(folder).appendingPathComponent("\(card.id).json"))
        #expect(throws: ProposalStore.Tampered.self) { try c.trustProposals([card.id], in: folder) }
        #expect(!c.isTrusted(card.id, in: folder))
        #expect(throws: ProposalStore.Tampered.self) { try c.loadTrusted(card.id, in: folder) }

        // A card this process never wrote is not trusted by its id alone.
        let dropped = Proposal.make(title: "Dropped in", actor: user, ops: [], now: now)
        try Data(JSONWriter.pretty(.object(dropped.raw)).utf8).write(to: ProposalStore.dir(folder).appendingPathComponent("\(dropped.id).json"))
        #expect(throws: Commands.Failure.self) { try c.trustProposals([dropped.id], in: folder) }
        #expect(!c.isTrusted(dropped.id, in: folder))

        // Bytes the caller checked itself are trusted by their own digest.
        let listed = try #require(ProposalStore.list(in: folder).first { $0.0.id == dropped.id })
        try c.trustChecked(dropped.id, digest: listed.1, in: folder)
        #expect(c.isTrusted(dropped.id, in: folder))
    }

    // MARK: - 2. Two writers approving one card apply it once

    @Test func aCardApprovedByAnotherWriterMeanwhileIsAppliedOnce() throws {
        let (folder, store) = try adopted()
        let item = JSONValue.obj([("id", .str("$new:1")), ("title", .str("Invented task")), ("status", .str("open")),
                                  ("priority", .str("normal")), ("no_deadline", .bool(true))])
        let card = Proposal.make(title: "Invented card", actor: user,
                                 ops: [JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", item)]))])],
                                 now: now)
        try ProposalStore.save(card, in: folder)
        // The other writer approves the same card after this one decided and before it takes the lock.
        let other = TekaStore(folder: folder)
        var otherLines: [JSONObject] = []
        store.testHookBeforeLock = { otherLines = (try? other.approve(card, now: self.now)) ?? [] }
        let lines = try store.approve(card, now: now)
        let adds = try store.readOpLog().ops.filter { $0["op"] == .str("add_item") }
        #expect(adds.count == 1)
        #expect(!otherLines.isEmpty && lines.map { $0["id"] } == otherLines.map { $0["id"] })
        #expect(try catalog(folder)["open_items"]?.arrayValue?.filter { $0["title"] == .str("Invented task") }.count == 1)
    }

    // MARK: - 3. Several ops written together are one batch

    @Test func severalOpsWithoutABatchIdAreRolledForwardTogether() throws {
        let (folder, store) = try adopted()
        struct Crash: Error {}
        store.testHookAfterAppend = { throw Crash() }
        #expect(throws: Crash.self) {
            try store.apply([dismiss("estate-example-2026-007"), dismiss("estate-example-2026-008")], now: now)
        }
        let logged = Array(try store.readOpLog().ops.suffix(2))
        #expect(logged.allSatisfy { $0["batch"]?.stringValue != nil && $0["batch_size"] == .int(2) })
        #expect(logged.map { $0["seq"] } == [.int(0), .int(1)])

        // The catalog was never renamed into place: the whole write is rolled forward, not taken for an edit.
        store.testHookAfterAppend = nil
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .rolledForward(2))
        let items = try catalog(folder)["open_items"]?.arrayValue ?? []
        for id in ["estate-example-2026-007", "estate-example-2026-008"] {
            #expect(items.first { $0["id"] == .string(id) }?["dismissed"] == .bool(true))
        }
        #expect(!(try store.readOpLog().ops.contains { $0["op"] == .str("external_edit") }))
    }

    // MARK: - 4. A filing aborted after an outside edit puts its file back

    @Test func aFilingAbortedAfterAnOutsideEditGoesBackToIntake() throws {
        let (folder, store) = try adopted()
        let catalogBefore = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        let snapshotBefore = try Data(contentsOf: folder.appendingPathComponent(".sprava/snapshot.json"))
        let sha = try intakeFile(folder, "letter.pdf", "invented letter")
        try store.apply([filing("intake/letter.pdf", to: "documents/2026-10-07_letter.pdf", sha: sha)], now: now)
        #expect(exists(folder, "documents/2026-10-07_letter.pdf"))
        // A crash after the move and before the rename, then an editor changes the old catalog.
        try snapshotBefore.write(to: folder.appendingPathComponent(".sprava/snapshot.json"))
        try editByHand(folder, from: catalogBefore)

        try store.settle(now: now)
        #expect(exists(folder, "intake/letter.pdf"))
        #expect(!exists(folder, "documents/2026-10-07_letter.pdf"))
        let ops = try store.readOpLog().ops
        let filed = try #require(ops.first { $0["op"] == .str("file_document") }?["id"])
        #expect(ops.contains { $0["op"] == .str("abort") && $0["args"]?["ops"]?.arrayValue?.contains(filed) == true })
        #expect(try catalog(folder)["documents"]?.arrayValue?.contains { $0["id"] == .str("estate-example-doc-2026-003") } == false)
    }

    // MARK: - 5. A document's new path follows the path rules and names a file that is there

    @Test func aDocumentPathIsCheckedBeforeItIsRecorded() throws {
        let (folder, store) = try adopted()
        func move(to path: String) -> TekaStore.OpBody {
            .init(op: "update_document", args: JSONObject([(key: "id", value: .str("estate-example-doc-2026-002")),
                                                           (key: "set", value: .obj([("path", .string(path))]))]), actor: user)
        }
        let before = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        for bad in ["../outside.txt", "intake/letter.pdf", "catalog.json", "/tmp/letter.pdf"] {
            #expect(throws: TransactionGuard.Rejection.self) { try store.apply([move(to: bad)], now: now) }
        }
        #expect(throws: TekaStore.Refused.self) { try store.apply([move(to: "correspondence/missing.pdf")], now: now) }
        // A link on the way is not inside the binder.
        let outside = folder.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: outside.appendingPathComponent("letter.pdf"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked"), withDestinationURL: outside)
        #expect(throws: TekaStore.Refused.self) { try store.apply([move(to: "linked/letter.pdf")], now: now) }
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == before)

        // A file moved outside, even under chapters/, is recorded where it now is.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("chapters/notary"), withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: folder.appendingPathComponent("chapters/notary/letter.pdf"))
        try store.apply([move(to: "chapters/notary/letter.pdf")], now: now)
        #expect(try catalog(folder)["documents"]?.arrayValue?.first { $0["id"] == .str("estate-example-doc-2026-002") }?["path"]
                == .str("chapters/notary/letter.pdf"))
    }

    // MARK: - 6. A key or credential file is never filed, not even by recovery

    @Test func aKeyFileIsNeverFiled() throws {
        let (folder, store) = try adopted()
        let key = try intakeFile(folder, "id_rsa", "invented key material")
        #expect(throws: TransactionGuard.Rejection.self) {
            try store.apply([filing("intake/id_rsa", to: "documents/note.txt", sha: key)], now: now)
        }
        let note = try intakeFile(folder, "notes.txt", "invented notes")
        #expect(throws: TransactionGuard.Rejection.self) {
            try store.apply([filing("intake/notes.txt", to: "documents/server.pem", sha: note)], now: now)
        }
        #expect(exists(folder, "intake/id_rsa") && exists(folder, "intake/notes.txt"))
        #expect(!exists(folder, "documents"))

        // A logged filing of a key file, as an older or a careless writer could leave it, is aborted, not finished.
        let (found, hash, _) = try store.readCatalog()
        var line = JSONObject()
        line.set("id", .string(UUIDv7.make(now: now)))
        line.set("at", .str("2026-10-07T09:00:00Z"))
        line.set("actor", .obj([("kind", .str("user")), ("client", .str("invented/1"))]))
        line.set("before_hash", .string(hash))
        line.set("after_hash", .null)
        line.set("op", .str("file_document"))
        line.set("args", .obj([("document", .obj([("id", .str("estate-example-doc-2026-003")), ("title", .str("Invented note")),
                                                  ("path", .str("documents/note.txt")), ("sha256", .string(key))])),
                               ("from", .str("intake/id_rsa"))]))
        line.set("after_hash", .string(try Canonical.hash(.object(try OpApplier.apply(line, to: found)))))
        try store.withLock { try store.appendLines([line]) }
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .aborted(1))
        #expect(exists(folder, "intake/id_rsa") && !exists(folder, "documents/note.txt"))
    }

    // MARK: - 7. A failed flush stops the write

    @Test func aFailedFlushStopsTheWrite() throws {
        let (folder, store) = try adopted()
        let before = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        store.testHookFlushFails = { $0 == "flush temp catalog" }
        #expect(throws: AtomicFile.Failure.self) { try store.apply([dismiss("estate-example-2026-007")], now: now) }
        #expect(try store.readOpLog().ops.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }.isEmpty)

        // The op log's flush fails: no file is moved and the catalog is not replaced.
        let sha = try intakeFile(folder, "letter.pdf", "invented letter")
        store.testHookFlushFails = { $0 == "flush op log" }
        #expect(throws: AtomicFile.Failure.self) {
            try store.apply([filing("intake/letter.pdf", to: "documents/2026-10-07_letter.pdf", sha: sha)], now: now)
        }
        #expect(exists(folder, "intake/letter.pdf") && !exists(folder, "documents/2026-10-07_letter.pdf"))
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == before)
    }

    // MARK: - 8. A recovery card that could not be saved is offered on the next pass

    @Test func aRecoveryCardThatCouldNotBeSavedIsMadeLater() throws {
        let (folder, store) = try adopted()
        let found = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        let applied = try store.apply([dismiss("estate-example-2026-007")], now: now)
        // Another program that read the catalog before the change renames its copy over it.
        try found.write(to: folder.appendingPathComponent("catalog.json"))
        func cards() -> [Proposal] {
            ProposalStore.list(in: folder).map(\.0).filter { $0.raw["provenance"]?["overwritten_ops"] == .array(applied.compactMap { $0["id"] }) }
        }

        // The proposals folder cannot be written: the edit is left unrecorded, so the loss is found again.
        let proposals = ProposalStore.dir(folder)
        try FileManager.default.createDirectory(at: proposals, withIntermediateDirectories: true)
        chmod(proposals.path, 0o500)
        defer { chmod(proposals.path, 0o700) }
        #expect(throws: (any Error).self) { try store.settle(now: now) }
        #expect(!(try store.readOpLog().ops.contains { $0["op"] == .str("external_edit") }))
        chmod(proposals.path, 0o700)

        // The op log cannot be written after the card was saved: the next pass writes over that card.
        let log = folder.appendingPathComponent(".sprava/ops.ndjson")
        chmod(log.path, 0o400)
        defer { chmod(log.path, 0o600) }
        #expect(throws: (any Error).self) { try store.settle(now: now) }
        #expect(cards().count == 1)
        chmod(log.path, 0o600)

        try store.settle(now: now)
        #expect(store.lastAbsorbed == .externalEdit(revertedLastBatch: true))
        #expect(cards().count == 1 && cards().first?.state == "proposed")
        #expect(store.createdProposals == cards().map(\.id))
        #expect(try store.readOpLog().ops.filter { $0["op"] == .str("external_edit") }.count == 1)
    }
}
