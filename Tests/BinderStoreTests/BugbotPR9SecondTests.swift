@testable import BinderStore
import BinderFormat
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from Codex Bugbot's second pass on the binder writer (PR #9): new filing folders flushed, adoption of
/// a newer catalog, rename arguments, a recovery card whose trust was cut short, and approval racing rejection.
/// Invented data only.
@Suite(.serialized) struct BugbotPR9SecondTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])

    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        return (folder, store)
    }

    func catalogData(_ folder: URL) throws -> Data { try Data(contentsOf: folder.appendingPathComponent("catalog.json")) }

    func dismiss(_ id: String) -> TekaStore.OpBody {
        .init(op: "dismiss", args: JSONObject([(key: "id", value: .string(id))]), actor: user)
    }

    func card(dismissing id: String) -> Proposal {
        let op = JSONObject([(key: "op", value: .str("dismiss")), (key: "args", value: .obj([("id", .string(id))]))])
        return Proposal.make(title: "Invented card", actor: user, ops: [op], now: now)
    }

    func stored(_ id: String, in folder: URL) throws -> Proposal {
        try ProposalStore.load(id, in: folder, expectedDigest: nil)
    }

    // MARK: - A new filing folder is linked durably: its parent is flushed

    @Test func newFilingFoldersAreFlushedInTheirParents() throws {
        let (folder, store) = try adopted()
        let intake = folder.appendingPathComponent("intake", isDirectory: true)
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: intake.appendingPathComponent("letter.pdf"))
        let sha = try #require(DocumentPaths.sha256(of: intake.appendingPathComponent("letter.pdf")))
        let filing = TekaStore.OpBody(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", .str("estate-example-doc-2026-003")), ("title", .str("Invented letter")),
                                          ("path", .str("archive/2026/letter.pdf")), ("sha256", .string(sha))])),
            (key: "from", value: .str("intake/letter.pdf")),
        ]), actor: user)

        // A failing flush of a new folder's parent stops the write before the file is moved.
        store.testHookFlushFails = { $0 == "flush the parent of a new folder" }
        #expect(throws: AtomicFile.Failure.self) { try store.apply([filing], now: now) }
        #expect(FileManager.default.fileExists(atPath: intake.appendingPathComponent("letter.pdf").path))

        // The logged write is finished on the next pass, and each new folder's parent is flushed: the binder folder
        // for archive/, and archive/ for archive/2026/.
        var steps: [String] = []
        store.testHookFlushFails = { steps.append($0); return false }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("archive"))
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .rolledForward(1))
        #expect(steps.filter { $0 == "flush the parent of a new folder" }.count == 2)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("archive/2026/letter.pdf").path))
    }

    // MARK: - A catalog of a newer version is never adopted

    @Test func aNewerCatalogIsNotAdopted() throws {
        let folder = try makeTeka(fixture: "sprava-v0") { folder in
            let url = folder.appendingPathComponent("catalog.json")
            var c = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
            var meta = try #require(c["meta"]?.objectValue)
            meta.set("format_version", .str("1"))
            c.set("meta", .object(meta))
            try Data(JSONWriter.pretty(.object(c)).utf8).write(to: url)
        }
        #expect(throws: TekaStore.Refused.self) {
            try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["catalog.json"])
    }

    // MARK: - A rename writes a usable name, the old one and a real date

    @Test func aRenameIsCheckedBeforeItIsApplied() throws {
        let (folder, _) = try adopted()
        let moved = folder.deletingLastPathComponent().appendingPathComponent("estate-renamed", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        let store = TekaStore(folder: moved)
        func rename(_ name: JSONValue, former: JSONValue = .str("estate-example"), until: JSONValue = .str("2026-11-06")) -> TekaStore.OpBody {
            .init(op: "rename_teka", args: JSONObject([(key: "name", value: name), (key: "former", value: former), (key: "until", value: until)]),
                  actor: user)
        }
        let before = try catalogData(moved)
        for bad in [rename(.str("estate-renamed"), former: .str("")), rename(.str("estate-renamed"), until: .str("tomorrow")),
                    rename(.str("estate-renamed"), former: .str("another-binder"))] {
            #expect(throws: TransactionGuard.Rejection.self) { try store.apply([bad], now: now) }
        }
        // The name is the folder's: a rename to anything else would leave the binder needing attention.
        for bad in [rename(.int(7)), rename(.str("estate-other"))] {
            #expect(throws: TekaStore.Refused.self) { try store.apply([bad], now: now) }
        }
        // The guard alone refuses a name that is no binder name, whatever the folder.
        var line = JSONObject([(key: "op", value: .str("rename_teka")), (key: "actor", value: .object(user))])
        line.set("args", .obj([("name", .str("a/b")), ("former", .str("estate-example")), ("until", .str("2026-11-06"))]))
        #expect(TransactionGuard.envelopeProblems(line).contains("rename_teka: name is a binder name"))
        #expect(try catalogData(moved) == before)

        try store.apply([rename(.str("estate-renamed"))], now: now)
        let teka = Teka.read(moved)
        #expect(teka.name == "estate-renamed")
        #expect(teka.catalog?["meta"]?["former_names"] == .array([.obj([("name", .str("estate-example")), ("until", .str("2026-11-06"))])]))
        #expect(!teka.reasons.contains("the folder name differs from meta.name"))
    }

    // MARK: - A recovery card whose trust was cut short is made again and trusted

    @Test func aRecoveryCardCutShortBeforeItWasTrustedIsTrustedLater() throws {
        let (folder, store) = try adopted()
        let commands = Commands(support: FileManager.default.temporaryDirectory.appendingPathComponent("sprava-review-\(UUID().uuidString)"),
                                deviceID: "dev")
        let found = try catalogData(folder)
        try store.apply([dismiss("estate-example-2026-007")], now: now)
        // Another program that read the catalog before the change writes its copy back.
        try found.write(to: folder.appendingPathComponent("catalog.json"))
        try store.settle(now: now)
        let id = try #require(store.createdProposals.first)
        let bytes = try Data(contentsOf: ProposalStore.dir(folder).appendingPathComponent("\(id).json"))

        // The process stops before the caller records the card's digest; a new process never wrote it.
        ProposalStore.forgetWritten(id, in: folder)
        #expect(throws: (any Error).self) { try commands.trustProposals([id], in: folder) }

        // The next pass finds nothing new in the catalog, makes the card again under its id and hands it over.
        let next = TekaStore(folder: folder)
        try next.settle(now: now.addingTimeInterval(60))
        #expect(next.createdProposals == [id])
        #expect(try Data(contentsOf: ProposalStore.dir(folder).appendingPathComponent("\(id).json")) == bytes)
        try commands.trustProposals(next.createdProposals, in: folder)
        #expect(commands.isTrusted(id, in: folder))
        #expect(ProposalStore.list(in: folder).filter { $0.0.raw["provenance"]?["overwritten_ops"] != nil }.count == 1)

        // A card another program rewrote meanwhile is written again from the log, never trusted as it was found.
        var raw = try stored(id, in: folder).raw
        raw.set("title", .str("Invented title, rewritten outside"))
        try Data(JSONWriter.pretty(.object(raw)).utf8).write(to: ProposalStore.dir(folder).appendingPathComponent("\(id).json"))
        ProposalStore.forgetWritten(id, in: folder)
        let third = TekaStore(folder: folder)
        try third.settle(now: now.addingTimeInterval(120))
        #expect(try Data(contentsOf: ProposalStore.dir(folder).appendingPathComponent("\(id).json")) == bytes)

        // Once the person decided, the card is left as it is.
        try third.reject(try stored(id, in: folder), now: now)
        let rejected = try Data(contentsOf: ProposalStore.dir(folder).appendingPathComponent("\(id).json"))
        let fourth = TekaStore(folder: folder)
        try fourth.settle(now: now.addingTimeInterval(180))
        #expect(fourth.createdProposals.isEmpty)
        #expect(try Data(contentsOf: ProposalStore.dir(folder).appendingPathComponent("\(id).json")) == rejected)
    }

    // MARK: - Approval and rejection of one card never both take effect

    @Test func approvalAndRejectionOfOneCardAreSerialized() throws {
        let (folder, store) = try adopted()
        // Rejected first: an approval that still holds the proposed card applies nothing.
        let first = card(dismissing: "estate-example-2026-007")
        try ProposalStore.save(first, in: folder)
        try store.reject(first, now: now)
        let opCount = try store.readOpLog().ops.count
        #expect(throws: TekaStore.Refused.self) { try store.approve(first, now: now) }
        #expect(try store.readOpLog().ops.count == opCount)
        #expect(try stored(first.id, in: folder).state == "rejected")

        // Applied first: a rejection that still holds the proposed card leaves it applied.
        let second = card(dismissing: "estate-example-2026-008")
        try ProposalStore.save(second, in: folder)
        try store.approve(second, now: now)
        try store.reject(second, now: now)
        #expect(try stored(second.id, in: folder).state == "applied")

        // Applied but not yet marked (a crash in between): a rejection leaves it for approval to mark.
        let third = card(dismissing: "estate-example-2026-009")
        try ProposalStore.save(third, in: folder)
        try store.approve(third, now: now)
        try ProposalStore.save(third, in: folder)
        try store.reject(third, now: now)
        #expect(try stored(third.id, in: folder).state == "proposed")
        try store.approve(third, now: now)
        #expect(try stored(third.id, in: folder).state == "applied")
    }
}
