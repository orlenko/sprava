import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from Bugbot's third pass on BinderStore part 2 (PR #10): undoing a closure keeps a hidden item hidden
/// and its privacy fields, and a kept dashboard copy is flushed before the original is replaced. Invented data only.
@Suite(.serialized) struct BugbotUndoDashboardTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07
    let user = JSONObject([(key: "kind", value: .str("user"))])

    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        return (folder, store)
    }

    @Test(arguments: ["complete", "drop"])
    func undoingTheClosureOfADismissedItemKeepsItHiddenAndRedacted(_ close: String) throws {
        let (folder, store) = try adopted()
        let id = JSONValue.str("estate-example-2026-007")
        try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: id), (key: "set", value: .obj([
            ("redact", .bool(true)), ("slice_title", .str("Invented errand"))]))]), actor: user)], now: now)
        try store.apply([.init(op: "dismiss", args: JSONObject([(key: "id", value: id)]), actor: user)], now: now)
        let closed = try store.apply([.init(op: close, args: JSONObject([
            (key: "id", value: id), (key: "closed_at", value: .str("2026-10-07T09:00:00Z")), (key: "source", value: .str("user"))]),
            actor: user)], now: now)
        try store.undo(opID: closed[0]["id"]!.stringValue!, now: now)

        let reopened = try #require(Teka.read(folder).items.last)
        #expect(reopened.object?["provenance"]?["reopened_from"] == id)
        #expect(reopened.isDismissed)
        #expect(reopened.object?["redact"] == .bool(true))
        #expect(reopened.object?["slice_title"] == .str("Invented errand"))
        #expect(reopened.object?["kind"] == .str("filing"))
        let ops = try store.readOpLog().ops
        #expect(ops.suffix(2).map { $0["op"]?.stringValue ?? "" } == ["reopen", "dismiss"])
        #expect(ops.suffix(2).allSatisfy { $0["compensates"] == closed[0]["id"] })
        #expect(.object(try Replay.run(ops)) == .object(try #require(Teka.read(folder).catalog)))
    }

    @Test func undoingTheClosureOfAVisibleItemAddsNoDismiss() throws {
        let (_, store) = try adopted()
        let closed = try store.apply([.init(op: "drop", args: JSONObject([
            (key: "id", value: .str("estate-example-2026-007")), (key: "closed_at", value: .str("2026-10-07T09:00:00Z")),
            (key: "source", value: .str("user"))]), actor: user)], now: now)
        try store.undo(opID: closed[0]["id"]!.stringValue!, now: now)
        #expect(try store.readOpLog().ops.last?["op"] == .str("reopen"))
    }

    struct FlushFailed: Error {}

    @Test func aDashboardCopyThatCannotBeFlushedStopsTheSwitch() throws {
        let (folder, _) = try adopted()
        let hand = "# Invented dashboard kept by hand\n\nRunning balance: invented 10\n"
        try Data(hand.utf8).write(to: folder.appendingPathComponent("DASHBOARD.md"))
        var keeper = DashboardKeeper(folder: folder)
        keeper.flushCopies = { _ in throw FlushFailed() }
        #expect(throws: FlushFailed.self) { try keeper.switchOn(today: today, timeZone: utc, now: now) }
        #expect(try String(contentsOf: folder.appendingPathComponent("DASHBOARD.md"), encoding: .utf8) == hand)
        #expect(!keeper.isSwitched)
    }

    @Test func aDashboardCopyIsFlushedOnceItIsInPlace() throws {
        let (folder, _) = try adopted()
        try Data("# Invented dashboard kept by hand\n".utf8).write(to: folder.appendingPathComponent("DASHBOARD.md"))
        final class Seen: @unchecked Sendable { var copies: [[String]] = [] }
        let seen = Seen()
        var keeper = DashboardKeeper(folder: folder)
        keeper.flushCopies = { dir in
            seen.copies.append(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("DASHBOARD-") })
        }
        try keeper.switchOn(today: today, timeZone: utc, now: now)
        #expect(seen.copies.count == 1)
        #expect(seen.copies.first?.count == 1)
    }
}
