import BinderFormat
import BinderStore
import Foundation
@testable import Hub
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// A binder narrowed to disclosure none takes its slice off the hub even when something else is wrong: a broken
/// outbox, a stamp that fails its checks, a linked dashboard, an unreadable catalog, a name another binder shares.
/// It never removes a slice it did not write. Binders and spools live in temporary folders; every value is invented.
@Suite(.serialized) struct HubWithdrawalTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    /// A lifeproj v2 binder adopted and its cards approved until it is ready, publishing at full, with a spool
    /// next to it (the `adopt` and `approve` commands, without the command layer).
    func readyBinder() throws -> (URL, URL) {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        _ = try Adoption.adopt(folder, inRegistry: true, deviceID: "dev", today: today, now: now)
        for _ in 0..<5 {
            let open = ProposalStore.list(in: folder).map(\.0).filter { $0.state == "proposed" }
            if open.isEmpty, try Adoption.offerStamp(folder, now: now) == nil { break }
            for card in open { _ = try TekaStore(folder: folder).approve(card, now: now) }
        }
        #expect(Teka.read(folder).state == .ready)
        let spool = folder.deletingLastPathComponent().appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (folder, spool)
    }

    /// Edits catalog.json the way another program would: no lock, no op.
    func outsideEdit(_ folder: URL, _ change: (inout JSONObject) -> Void) throws {
        let url = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
        change(&catalog)
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
    }

    func setMeta(_ key: String, _ value: JSONValue) -> (inout JSONObject) -> Void {
        { c in
            var meta = c["meta"]?.objectValue ?? JSONObject()
            meta.set(key, value)
            c.set("meta", .object(meta))
        }
    }

    /// A direct action by the person (the `apply` command).
    func apply(_ folder: URL, _ op: String, _ args: JSONObject) throws {
        let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("t"))])
        _ = try TekaStore(folder: folder).apply([.init(op: op, args: args, actor: actor)], now: now)
    }

    func sliceURL(_ spool: URL, _ name: String) -> URL { spool.appendingPathComponent("inbox/\(name).agenda.json") }

    @Test func aBrokenOutboxDoesNotKeepAWithdrawnSliceOnTheHub() throws {
        let (folder, spool) = try readyBinder()
        let slice = sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        let outbox = spool.appendingPathComponent("outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("{ not json".utf8).write(to: outbox.appendingPathComponent("rental-elm-street.intake.json"))
        #expect(throws: (any Error).self) { try HubLane.drain(folder, root: spool, now: now) }

        // A redaction narrows the projection: published although the drain fails.
        try apply(folder, "update_item", JSONObject([(key: "id", value: .str("item-0006")),
                                                     (key: "set", value: .obj([("redact", .bool(true)), ("kind", .str("payment"))]))]))
        let narrowed = HubLane.sync(folder, root: spool, now: now)
        #expect(narrowed.drainError != nil && narrowed.failed)
        guard case .published? = narrowed.published else { Issue.record("not published: \(String(describing: narrowed.publishError))"); return }
        let titles = try JSONParser.parse(try Data(contentsOf: slice)).value["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
        #expect(titles.contains("[redacted]"))

        // Disclosure none withdraws the slice although the drain fails.
        try outsideEdit(folder, setMeta("disclosure", .str("none")))
        let withdrawn = HubLane.sync(folder, root: spool, now: now)
        #expect(withdrawn.drainError != nil)
        #expect(withdrawn.published == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }

    @Test func aBrokenStampDoesNotKeepAWithdrawnSlice() throws {
        let (folder, spool) = try readyBinder()
        let slice = sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        // Publishing new content still needs every check.
        let before = try Data(contentsOf: slice)
        try outsideEdit(folder) { c in
            setMeta("format", .str("teka"))(&c)
            setMeta("format_version", .str("v-zero"))(&c)
        }
        #expect(Teka.read(folder).federationBlocked)
        #expect(try HubLane.publish(folder, root: spool, now: now) == .notPublished("the binder needs attention"))
        #expect(try Data(contentsOf: slice) == before)
        // Disclosure none withdraws it all the same.
        try outsideEdit(folder, setMeta("disclosure", .str("none")))
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
        #expect(HubLane.loadCursors(folder).sliceHash == nil)
    }

    @Test func aLinkedDashboardDoesNotKeepAWithdrawnSlice() throws {
        let (folder, spool) = try readyBinder()
        let slice = sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        let dashboard = folder.appendingPathComponent("DASHBOARD.md")
        let elsewhere = folder.deletingLastPathComponent().appendingPathComponent("invented-elsewhere.md")
        try Data("invented".utf8).write(to: elsewhere)
        try? FileManager.default.removeItem(at: dashboard)
        try FileManager.default.createSymbolicLink(at: dashboard, withDestinationURL: elsewhere)
        try outsideEdit(folder, setMeta("disclosure", .str("none")))
        #expect(Teka.read(folder).federationBlocked)
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }

    @Test func aWithdrawalNeverFollowsTheCatalogToAnotherBindersSlice() throws {
        let (folder, spool) = try readyBinder()
        let slice = sliceURL(spool, "rental-elm-street")
        let other = sliceURL(spool, "invented-other-binder")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        try Data(#"{"teka": "invented-other-binder", "items": []}"#.utf8).write(to: other)
        #expect(HubLane.loadCursors(folder).sliceName == "rental-elm-street")
        // An outside edit renames the binder to another one's name and narrows it: its own slice goes, never the other.
        try outsideEdit(folder) { c in
            setMeta("name", .str("invented-other-binder"))(&c)
            setMeta("disclosure", .str("none"))(&c)
        }
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        // With nothing of its own left on the hub, a blocked binder removes nothing, even under its folder's name.
        try Data(#"{"teka": "rental-elm-street", "items": []}"#.utf8).write(to: slice)
        #expect(try HubLane.publish(folder, root: spool, now: now) == .notPublished("the binder needs attention"))
        #expect(FileManager.default.fileExists(atPath: slice.path) && FileManager.default.fileExists(atPath: other.path))
    }

    @Test func anUnreadableCatalogWithdrawsByTheConfirmedDisclosure() throws {
        let (folder, spool) = try readyBinder()
        let slice = sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        try apply(folder, "set_disclosure", JSONObject([(key: "disclosure", value: .str("none"))]))
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("catalog.json"))
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }

    @Test func aCollidingBinderWithdrawsTheSliceItRecordedAndNothingElse() throws {
        let (a, spool) = try readyBinder()
        let (b, _) = try readyBinder()
        let slice = sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(a, root: spool, now: now) else { Issue.record("not published"); return }
        #expect(HubLane.collidingFolders(Shelf.rows(registry: nil, picked: [a, b]), today: today)
                == [a.standardizedFileURL.path, b.standardizedFileURL.path])
        // At full, a colliding binder neither drains nor publishes, and that is a failure.
        let published = try Data(contentsOf: slice)
        let blocked = HubLane.sync(b, root: spool, now: now, nameCollides: true)
        #expect(blocked.failed && blocked.drained == nil && blocked.drainError == nil)
        #expect(blocked.published == .notPublished("another binder has the same name"))
        #expect(try Data(contentsOf: slice) == published)
        // B narrows: it recorded no slice, so the one under the shared name (A's) stays.
        try outsideEdit(b, setMeta("disclosure", .str("none")))
        #expect(HubLane.sync(b, root: spool, now: now, nameCollides: true).published == .notPublished("the binder needs attention"))
        #expect(try Data(contentsOf: slice) == published)
        // A narrows: the slice it recorded writing goes, though its name still collides.
        try outsideEdit(a, setMeta("disclosure", .str("none")))
        let withdrawn = HubLane.sync(a, root: spool, now: now, nameCollides: true)
        #expect(withdrawn.published == .removed && withdrawn.failed && withdrawn.drained == nil)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
        #expect(HubLane.loadCursors(a).sliceHash == nil && HubLane.loadCursors(a).sliceName == nil)
    }
}
