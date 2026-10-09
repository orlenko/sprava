import Backup
import BinderFormat
import BinderStore
import Darwin
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the fifth adversarial review of increment 1 (key files named by an inline MIME part, numbers in
/// untrusted text that overflowed, withdrawals a failing binder check held back, unreadable backup settings).
/// Invented data only.
@Suite(.serialized) struct AstraReview5Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    let today = CalendarDate(year: 2026, month: 10, day: 6)!

    func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra5-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 3. A withdrawal never waits on the checks publishing needs

    @Test func aBrokenStampDoesNotKeepAWithdrawnSlice() throws {
        let ops = BugbotOpsTests()
        let (folder, spool) = try ops.readyBinder(ops.commands())
        let slice = ops.sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }

        // Publishing new content still needs every check.
        let before = try Data(contentsOf: slice)
        try ops.outsideEdit(folder) { c in
            ops.setMeta("format", .str("teka"))(&c)
            ops.setMeta("format_version", .str("v-zero"))(&c)
        }
        #expect(Teka.read(folder).federationBlocked)
        #expect(try HubLane.publish(folder, root: spool, now: now) == .notPublished("the binder needs attention"))
        #expect(try Data(contentsOf: slice) == before)

        // Disclosure none withdraws it all the same.
        try ops.outsideEdit(folder, ops.setMeta("disclosure", .str("none")))
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
        #expect(HubLane.loadCursors(folder).sliceHash == nil)
    }

    @Test func aLinkedDashboardDoesNotKeepAWithdrawnSlice() throws {
        let ops = BugbotOpsTests()
        let (folder, spool) = try ops.readyBinder(ops.commands())
        let slice = ops.sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        let dashboard = folder.appendingPathComponent("DASHBOARD.md")
        let elsewhere = temp("dashboard").appendingPathComponent("invented.md")
        try Data("invented".utf8).write(to: elsewhere)
        try? FileManager.default.removeItem(at: dashboard)
        try FileManager.default.createSymbolicLink(at: dashboard, withDestinationURL: elsewhere)
        try ops.outsideEdit(folder, ops.setMeta("disclosure", .str("none")))
        #expect(Teka.read(folder).federationBlocked)
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }

    @Test func aWithdrawalNeverFollowsTheCatalogToAnotherBindersSlice() throws {
        let ops = BugbotOpsTests()
        let (folder, spool) = try ops.readyBinder(ops.commands())
        let slice = ops.sliceURL(spool, "rental-elm-street")
        let other = ops.sliceURL(spool, "invented-other-binder")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        try Data(#"{"teka": "invented-other-binder", "items": []}"#.utf8).write(to: other)
        #expect(HubLane.loadCursors(folder).sliceName == "rental-elm-street")

        // An outside edit renames the binder to another one's name and narrows it: its own slice goes, never the other.
        try ops.outsideEdit(folder) { c in
            ops.setMeta("name", .str("invented-other-binder"))(&c)
            ops.setMeta("disclosure", .str("none"))(&c)
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
        let ops = BugbotOpsTests()
        let c = ops.commands()
        let (folder, spool) = try ops.readyBinder(c)
        let slice = ops.sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        _ = try ops.apply(c, folder, "set_disclosure", .obj([("disclosure", .str("none"))]))
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("catalog.json"))
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }

    @Test func backupStatusReportsUnreadableSettings() throws {
        let support = temp("support")
        let c = Commands(support: support, deviceID: "dev")
        let b = Backup(support: support, key: nil)
        try AtomicFile.makePrivateFolder(b.dir)
        try Data("{ not json".utf8).write(to: b.settingsURL)
        let reply = try JSONParser.parse(c.handle(JSONWriter.compact(.obj([("command", .str("backup_status"))])), now: now, today: today)).value
        #expect(reply["ok"] == .bool(false))
        #expect(reply["error"]?.stringValue?.contains("backup settings are unreadable") == true)
    }
}
