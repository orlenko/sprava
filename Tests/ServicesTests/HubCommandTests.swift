import BinderFormat
import BinderStore
import Darwin
import Foundation
import Hub
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The hub through the command table: the privacy ratchet, narrowing, the slice key, cursors and the outbox, and
/// closed duplicates (architecture 4.5, 7). Invented data only.
@Suite(.serialized) struct HubCommandTests: BinderCommandFixture {
    // MARK: - The privacy ratchet (qIlEh)

    @Test func anOutsideDisclosureWideningWaitsForAPrivacyCard() throws {
        let c = commands()
        let (folder, spool) = try createdBinder(c)
        try outsideEdit(folder, setMeta("disclosure", .str("full")))
        // The hub sees nothing until the person approves.
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: sliceURL(spool, "estate-sample").path))
        // The card is the person's own set_disclosure, verified, and made once.
        let listed = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? []
        let card = try #require(listed.first { $0["lines"]?.arrayValue?.first?.stringValue?.hasPrefix("Set disclosure to full") == true })
        #expect(card["verified"] == .bool(true))
        #expect(card["lines"]?.arrayValue?.first?.stringValue?.contains("privacy change") == true)
        let again = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? []
        #expect(again.count == listed.count)
        let r = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        #expect(r["ok"] == .bool(true), "\(r)")
        #expect(try HubLane.publish(folder, root: spool, now: now) == .published(items: 0, overwrittenByOther: false))
    }


    @Test func anOutsideRedactionLiftStaysRedactedOnTheHub() throws {
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("redact", .bool(true)), ("kind", .str("payment"))]))]))
        // Lifted outside before any publish, so the hub cursors never saw the redaction.
        try outsideEdit(folder, updateItem("item-0006") { $0.remove("redact") })
        _ = try HubLane.publish(folder, root: spool, now: now)
        let slice = try JSONParser.parse(try Data(contentsOf: sliceURL(spool, "rental-elm-street"))).value
        let titles = slice["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
        #expect(titles.contains("[redacted]"))
        let lines = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue?
            .flatMap { $0["lines"]?.arrayValue ?? [] }.compactMap(\.stringValue) ?? []
        #expect(lines.contains { $0.contains("remove redact") && $0.contains("privacy change") })
    }

    @Test func narrowingTakesEffectAtOnce() throws {
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        try outsideEdit(folder, setMeta("disclosure", .str("none")))
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: sliceURL(spool, "rental-elm-street").path))
    }

    // MARK: - Hub lane

    @Test func narrowingToTitleWithdrawsTheFullSlice() throws {   // p8-QK
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        _ = try apply(c, folder, "set_disclosure", .obj([("disclosure", .str("title"))]))
        guard case .notPublished = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("expected notPublished"); return }
        #expect(!FileManager.default.fileExists(atPath: sliceURL(spool, "rental-elm-street").path))
        #expect(HubLane.loadCursors(folder).sliceHash == nil)
    }

    @Test func unreadableCursorsStopPublishing() throws {   // qIe1n
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("redact", .bool(true)), ("kind", .str("payment"))]))]))
        _ = try HubLane.publish(folder, root: spool, now: now)
        let before = try Data(contentsOf: sliceURL(spool, "rental-elm-street"))
        try outsideEdit(folder, updateItem("item-0006") { $0.remove("redact") })
        try Data("{".utf8).write(to: folder.appendingPathComponent(".sprava/cursors.json"))
        #expect(throws: TekaStore.Refused.self) { try HubLane.publish(folder, root: spool, now: now) }
        #expect(try Data(contentsOf: sliceURL(spool, "rental-elm-street")) == before)
        #expect(String(decoding: before, as: UTF8.self).contains("[redacted]"))
    }

    @Test func aFailedSliceRemovalIsReported() throws {   // qHLt7
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        let hash = HubLane.loadCursors(folder).sliceHash
        let inbox = spool.appendingPathComponent("inbox")
        chmod(inbox.path, 0o500)
        defer { chmod(inbox.path, 0o700) }
        _ = try apply(c, folder, "set_disclosure", .obj([("disclosure", .str("none"))]))
        #expect(throws: TekaStore.Refused.self) { try HubLane.publish(folder, root: spool, now: now) }
        #expect(HubLane.loadCursors(folder).sliceHash == hash)
    }

    @Test func anUnreadableOutboxIsAFailure() throws {   // qHLuC
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        #expect(try HubLane.drain(folder, root: spool, now: now) == HubLane.DrainResult())
        let outbox = spool.appendingPathComponent("outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(try HubLane.drain(folder, root: spool, now: now) == HubLane.DrainResult())
        let file = outbox.appendingPathComponent("rental-elm-street.intake.json")
        try Data(#"{"completions":[{"id":"item-0003","action":"done","at":"2026-10-07T08:00:00Z"}]}"#.utf8).write(to: file)
        chmod(file.path, 0o000)
        defer { chmod(file.path, 0o600) }
        #expect(throws: TekaStore.Refused.self) { try HubLane.drain(folder, root: spool, now: now) }
    }

    @Test func aDeletedSliceIsPublishedAgain() throws {   // qIlEJ
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        try FileManager.default.removeItem(at: sliceURL(spool, "rental-elm-street"))
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("expected published"); return }
        #expect(FileManager.default.fileExists(atPath: sliceURL(spool, "rental-elm-street").path))
        #expect(try HubLane.publish(folder, root: spool, now: now) == .unchanged)
    }

    @Test func aDamagedSliceKeyIsNeverReplaced() throws {   // qI0_M
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        let keyURL = folder.appendingPathComponent(".sprava/slice-key")
        let short = Data(repeating: 7, count: 10)
        try short.write(to: keyURL)
        _ = try apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("priority", .str("high"))]))]))
        #expect(throws: TekaStore.Refused.self) { try HubLane.publish(folder, root: spool, now: now) }
        #expect(try Data(contentsOf: keyURL) == short)
    }

    @Test func aClosedDuplicateShowsOnceAsDone() throws {   // p8-RS
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        // A hand-written closure with another action leaves the item open with a closed id.
        try outsideEdit(folder) { cat in
            var log = cat["processing_log"]?.arrayValue ?? []
            log.append(.obj([("id", .str("item-0006")), ("action", .str("completed")), ("at", .str("2026-10-07"))]))
            cat.set("processing_log", .array(log))
        }
        let r = try apply(c, folder, "complete", .obj([("id", .str("item-0006"))]))
        #expect(r["ok"] == .bool(true), "\(r)")
        _ = try HubLane.publish(folder, root: spool, now: now)
        let items = try JSONParser.parse(try Data(contentsOf: sliceURL(spool, "rental-elm-street"))).value["items"]?.arrayValue ?? []
        let shown = items.filter { $0["id"] == .str("rental-elm-street-item-0006") }
        #expect(shown.count == 1 && shown.first?["status"] == .str("done"))
    }
}
