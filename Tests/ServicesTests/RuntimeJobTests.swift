import BinderFormat
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The runtime's first jobs as functions, without timers: the deadline sentinel, the daily summary, the hourly
/// alerts check, and the watchdog's verdict. Temporary folders and invented binders only.
@Suite(.serialized) struct RuntimeJobTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-jobs-\(UUID().uuidString)", isDirectory: true)
        try AtomicFile.makePrivateFolder(url.appendingPathComponent("runtime"))
        return url
    }

    @Test func theSentinelRecordsTheDayUnderOpaqueIDs() throws {
        let support = try folder(), runtime = support.appendingPathComponent("runtime")
        let binder = try makeTeka(fixture: "sprava-v0")
        let (outcome, day) = SentinelJob.run(rows: { Shelf.rows(registry: nil, picked: [binder]) }, support: support,
                                             runtimeDir: runtime, idsLock: NSLock(), now: now, timeZone: utc)
        #expect(outcome == .ok && day == CalendarDate.today(in: utc, now: now).description)
        let recorded = try #require(day)
        let report = try #require(SentinelJob.report(runtimeDir: runtime, today: recorded))
        #expect(Array(report.binders.keys) == ["b1"])
        #expect(!String(decoding: try Data(contentsOf: SentinelJob.reportURL(runtime)), as: UTF8.self).contains("estate"))
        #expect(SentinelJob.report(runtimeDir: runtime, today: "2000-01-01") == nil)
    }

    @Test func theSentinelIsIdleWithAnEmptyShelfAndFailsOnAnUnreadableOneOrIDs() throws {
        let support = try folder(), runtime = support.appendingPathComponent("runtime")
        #expect(SentinelJob.run(rows: { [] }, support: support, runtimeDir: runtime, idsLock: NSLock(), now: now).outcome == .idle)
        struct Unreadable: Error {}
        let unreadable = SentinelJob.run(rows: { throw Unreadable() }, support: support, runtimeDir: runtime, idsLock: NSLock(), now: now)
        #expect(unreadable.outcome == SentinelJob.shelfUnreadable && unreadable.day == nil)
        try Data("{\"byPath\": ".utf8).write(to: support.appendingPathComponent("binder-ids.json"))
        let ids = SentinelJob.run(rows: { [] }, support: support, runtimeDir: runtime, idsLock: NSLock(), now: now)
        #expect(ids.outcome == .error(code: "binder_ids_unreadable", culprit: nil) && ids.day == nil)
    }

    func report(_ text: Bool) -> SentinelReport {
        var report = SentinelReport(date: "2026-10-07", computed_at: "2026-10-07T08:00:00Z", binders: [:])
        if text { report.binders["b1"] = .init(state: "ready", overdue: 1) }
        return report
    }

    @Test func theSummaryIsSentOnceADayWithCountsOnly() {
        var posted: [String] = []
        let input = SummaryJob.Inputs(today: "2026-10-07", lastSent: "2026-10-06", report: { report(true) }, sentinelBreaker: nil,
                                      runSentinel: {}, notify: { _, body, _ in posted.append(body); return true })
        let first = SummaryJob.run(input)
        #expect(first.outcome == .ok && first.sent == "2026-10-07" && posted == ["1 overdue"])
        var again = input
        again.lastSent = "2026-10-07"
        #expect(SummaryJob.run(again).outcome == .skipped && posted.count == 1)
    }

    @Test func aSummaryWaitsForTheSentinelWithoutConsumingItsScheduledRun() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var scheduler = Scheduler(now: now, lastSummaryDate: nil, lastSentinelDate: nil, calendar: calendar)
        let due = scheduler.due(now: now)
        #expect(due.contains("sentinel") && due.contains("summary"))
        scheduler.started("sentinel", now: now)
        // The due list was computed before the sentinel started. Eligibility is checked again for the summary.
        #expect(!Scheduler.mayStart("summary", running: ["sentinel"]))
        #expect(!Scheduler.mayStart("sentinel", running: ["sentinel"]))
        #expect(Scheduler.mayStart("alerts", running: ["sentinel"]))
        let later = now.addingTimeInterval(30)
        #expect(scheduler.due(now: later, sentinelRunning: true).contains("summary"))
        #expect(Scheduler.mayStart("summary", running: []))
        var scans = 0, notifications = 0
        let result = SummaryJob.run(.init(today: "2026-10-07", lastSent: nil, report: { report(true) },
                                         sentinelBreaker: nil, runSentinel: { scans += 1 },
                                         notify: { _, _, _ in notifications += 1; return true }))
        #expect(result.outcome == .ok && result.sent == "2026-10-07")
        #expect(scans == 0 && notifications == 1)
    }

    @Test func theSummaryRunsTheSentinelWhenNeededButNeverPastItsOpenBreaker() {
        var fresh: SentinelReport?
        var ran = 0
        var input = SummaryJob.Inputs(today: "2026-10-07", lastSent: nil, report: { fresh }, sentinelBreaker: nil,
                                      runSentinel: { ran += 1; fresh = report(false) }, notify: { _, _, _ in true })
        // No report yet: the sentinel runs; a day with nothing to say still counts as sent.
        #expect(SummaryJob.run(input) == (.ok, "2026-10-07") as (JobOutcome, String?))
        #expect(ran == 1)
        fresh = nil
        input.sentinelBreaker = "open"
        let stale = SummaryJob.run(input)
        #expect(stale.outcome == .error(code: "sentinel_stale", culprit: "sentinel breaker open") && stale.sent == nil && ran == 1)
    }

    @Test func theSummarySkipsOutsideTheAppAndFailsWhenItCannotPost() {
        var input = SummaryJob.Inputs(today: "2026-10-07", lastSent: nil, report: { report(true) }, sentinelBreaker: nil,
                                      runSentinel: {}, notify: nil)
        #expect(SummaryJob.run(input).outcome == .skipped && SummaryJob.run(input).sent == nil)
        input.notify = { _, _, _ in false }
        #expect(SummaryJob.run(input).outcome == .error(code: "notification_failed", culprit: nil))
    }

    @Test func theAlertsCheckRecordsWhatItSawAndKeepsTheClerksLastSuccess() {
        let model = Heartbeat.Model(availability: "available", context_size: 4096)
        let on = AlertsJob.run(authorized: { true }, model: { model }, lastModelSuccess: "2026-10-07T07:00:00Z", now: now)
        #expect(on.outcome == .ok && on.alerts.authorized && on.model.last_success == "2026-10-07T07:00:00Z")
        let off = AlertsJob.run(authorized: { false }, model: { model }, lastModelSuccess: nil, now: now)
        #expect(off.outcome == .ok && !off.alerts.authorized)
        // A development run: no notification identity, recorded as skipped with alerts off.
        let dev = AlertsJob.run(authorized: { nil }, model: { model }, lastModelSuccess: nil, now: now)
        #expect(dev.outcome == .skipped && !dev.alerts.authorized)
    }

    @Test func theWatchdogEndsAStalledOrWedgedRuntime() {
        #expect(Watchdog.verdict(sinceTickMoved: .seconds(60), wedged: nil) == .fine)
        #expect(Watchdog.verdict(sinceTickMoved: .seconds(121), wedged: nil) == .stalled)
        #expect(Watchdog.verdict(sinceTickMoved: .seconds(10), wedged: "backup") == .wedged(job: "backup"))
        #expect(Watchdog.verdict(sinceTickMoved: .seconds(121), wedged: "backup") == .stalled)
    }
}
