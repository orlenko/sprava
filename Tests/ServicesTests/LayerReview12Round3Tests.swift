import BinderFormat
import BinderStore
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the first calibrated review of the rebuilt Services layer: a card held back for trust survives
/// a binder that is away for a while, and a failed morning summary is tried again the same day. Invented data only.
@Suite(.serialized) struct LayerReview12Round3Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    /// A card Sprava wrote whose digest could not be recorded: it waits in the backlog.
    func heldCard() throws -> (Commands, URL, TrustBacklog, String, Data) {
        let ops = BugbotOpsTests()
        let c = ops.commands()
        let (folder, _) = try ops.readyBinder(c)
        let digests = c.support.appendingPathComponent("runtime/proposal-digests.json")
        let recorded = try Data(contentsOf: digests)
        let card = Proposal.make(title: "Invented card", actor: ops.user, ops: [ops.body("drop", .obj([
            ("id", .str("item-0006")), ("closed_at", .str("2026-10-06T08:00:00Z")), ("source", .str("user"))]))], now: now)
        try ProposalStore.save(card, in: folder)
        try Data("not json".utf8).write(to: digests)
        let backlog = TrustBacklog(support: c.support)
        #expect(throws: (any Error).self) { try backlog.trust([card.id], in: folder, commands: c) }
        #expect(backlog.count == 1)
        try recorded.write(to: digests)
        return (c, folder, backlog, card.id, recorded)
    }

    @Test func aCardStaysInTheBacklogWhileItsBinderIsAway() throws {
        let (c, folder, backlog, id, _) = try heldCard()
        // The binder's disk is away: the card cannot be read, so it is neither recorded nor dropped, and the pass fails.
        let away = folder.deletingLastPathComponent().appendingPathComponent("away-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: folder, to: away)
        #expect(throws: (any Error).self) { try backlog.retry(commands: c) }
        #expect(backlog.count == 1)
        #expect(FileManager.default.fileExists(atPath: backlog.url.path))
        // A restart finds it in the file too.
        #expect(throws: (any Error).self) { try TrustBacklog(support: c.support).retry(commands: c) }

        // Back again, unchanged: recorded, and the backlog is empty.
        try FileManager.default.moveItem(at: away, to: folder)
        try backlog.retry(commands: c)
        #expect(c.isTrusted(id, in: folder))
        #expect(backlog.count == 0)
        #expect(!FileManager.default.fileExists(atPath: backlog.url.path))
    }

    @Test func aCardRemovedFromItsBinderLeavesTheBacklog() throws {
        let (c, folder, backlog, id, _) = try heldCard()
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".sprava/proposals/\(id).json"))
        try backlog.retry(commands: c)
        #expect(backlog.count == 0)
        #expect(!c.isTrusted(id, in: folder))
    }

    // MARK: - A failed summary is tried again today, a bounded number of times

    var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Toronto")!
        return cal
    }

    func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: hour, minute: minute))!
    }

    @Test func aFailedSummaryIsRetriedTheSameDay() {
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 8, minute: 0))!
        let failed = JobOutcome.error(code: "notification_failed", culprit: nil)
        #expect(SummaryRetry.next(after: failed, now: at(8, 0), failedToday: 1, calendar: calendar) == at(8, 10))
        #expect(SummaryRetry.next(after: .timeout, now: at(9, 0), failedToday: 2, calendar: calendar) == at(9, 10))
        // Handled (sent, or skipped on purpose): tomorrow.
        #expect(SummaryRetry.next(after: .ok, now: at(8, 0), failedToday: 1, calendar: calendar) == tomorrow)
        #expect(SummaryRetry.next(after: .skipped, now: at(8, 0), failedToday: 0, calendar: calendar) == tomorrow)
        // Bounded: after the last retry, and never past midnight into tomorrow's summary.
        #expect(SummaryRetry.next(after: failed, now: at(9, 0), failedToday: SummaryRetry.maxRetries + 1, calendar: calendar) == tomorrow)
        #expect(SummaryRetry.next(after: failed, now: at(23, 55), failedToday: 1, calendar: calendar) == tomorrow)
    }
}
