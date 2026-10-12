import Foundation
@testable import Services
import SpravaKit
import Testing

/// Which jobs are due when (architecture 3.4), without timers: every case feeds the scheduler a clock.
@Suite struct SchedulerTests {
    let toronto: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0, in calendar: Calendar? = nil) -> Date {
        (calendar ?? toronto).date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func atTheStartEveryJobIsDueAndTheSummaryOnlyAfterEight() {
        let early = Scheduler(now: at(7, 7), lastSummaryDate: "2026-10-06", lastSentinelDate: nil, calendar: toronto)
        #expect(early.due(now: at(7, 7)) == ["sentinel", "alerts", "hub", "capture", "clerk", "dashboard", "backup", "intake"])
        #expect(early.due(now: at(7, 8)).contains("summary"))
        // Started late that day without having sent it: it goes at once. Sent already: tomorrow.
        let late = Scheduler(now: at(7, 11), lastSummaryDate: "2026-10-06", lastSentinelDate: nil, calendar: toronto)
        #expect(late.due(now: at(7, 11)).contains("summary"))
        let sent = Scheduler(now: at(7, 11), lastSummaryDate: "2026-10-07", lastSentinelDate: nil, calendar: toronto)
        #expect(!sent.due(now: at(7, 23)).contains("summary"))
        #expect(sent.due(now: at(8, 8)).contains("summary"))
    }

    @Test func aStartedJobWaitsItsPeriodAndTheOthersDoNot() {
        let t0 = at(7, 9)
        var s = Scheduler(now: t0, lastSummaryDate: "2026-10-07", lastSentinelDate: nil, calendar: toronto)
        for key in Scheduler.order { s.started(key, now: t0) }
        #expect(s.due(now: t0.addingTimeInterval(1)) == ["capture", "clerk", "backup"])
        #expect(s.due(now: t0.addingTimeInterval(30)) == ["capture", "clerk", "backup", "intake"])
        #expect(s.due(now: t0.addingTimeInterval(60)).contains("dashboard"))
        #expect(s.due(now: t0.addingTimeInterval(300)).contains("hub"))
        #expect(!s.due(now: t0.addingTimeInterval(3599)).contains("sentinel"))
        #expect(s.due(now: t0.addingTimeInterval(3600)).contains("sentinel") && s.due(now: t0.addingTimeInterval(3600)).contains("alerts"))
        // The summary, once started, waits for tomorrow's 08:00.
        #expect(s.nextSummary == at(8, 8))
    }

    @Test func aClockSetBackMakesEveryIntervalJobDue() {
        let later = at(7, 12)
        var s = Scheduler(now: later, lastSummaryDate: "2026-10-07", lastSentinelDate: nil, calendar: toronto)
        for key in Scheduler.order { s.started(key, now: later) }
        let back = at(7, 9)
        #expect(s.due(now: back) == ["capture", "clerk", "backup"])
        s.clockChanged(now: back)
        #expect(s.due(now: back) == ["sentinel", "alerts", "hub", "capture", "clerk", "dashboard", "backup", "intake"])
    }

    @Test func aTimeZoneChangeDoesNotSkipTheSummary() {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = at(7, 7, 30)
        #expect(Scheduler.nextSummaryTime(now: now, lastSent: "2026-10-06", calendar: paris) == now)
        #expect(Scheduler.nextSummaryTime(now: now, lastSent: "2026-10-07", calendar: paris) > now)
        #expect(Scheduler.nextSummaryTime(now: now, lastSent: "2026-10-06", calendar: toronto) > now)
    }

    @Test func nextClockTimeRollsToTomorrow() {
        #expect(Scheduler.nextClockTime(hour: 8, minute: 0, after: at(7, 7, 59), calendar: toronto) == at(7, 8))
        #expect(Scheduler.nextClockTime(hour: 8, minute: 0, after: at(7, 8), calendar: toronto) == at(8, 8))
    }

    @Test func aWakeRunsTheSentinelAtOnce() {
        let t0 = at(7, 9)
        var s = Scheduler(now: t0, lastSummaryDate: "2026-10-07", lastSentinelDate: "2026-10-07", calendar: toronto)
        s.started("sentinel", now: t0)
        #expect(!s.due(now: t0.addingTimeInterval(600)).contains("sentinel"))
        s.woke(now: t0.addingTimeInterval(600))
        #expect(s.due(now: t0.addingTimeInterval(600)).contains("sentinel"))
    }

    @Test func theSentinelRunsAgainWhenTheDateChangesUnlessItIsRunning() {
        let t0 = at(7, 23, 30)
        var s = Scheduler(now: t0, lastSummaryDate: "2026-10-07", lastSentinelDate: nil, calendar: toronto)
        s.started("sentinel", now: t0)
        s.sentinelRan(day: "2026-10-07")
        #expect(!s.due(now: at(7, 23, 59)).contains("sentinel"))
        #expect(s.due(now: at(8, 0, 1)).contains("sentinel"))
        #expect(!s.due(now: at(8, 0, 1), sentinelRunning: true).contains("sentinel"))
        s.sentinelRan(day: "2026-10-08")
        #expect(!s.due(now: at(8, 0, 2)).contains("sentinel"))
    }

    @Test func aBackupThatStopsSucceedingTurnsAmberThenRed() {
        let spec = Scheduler.specs["backup"]!
        let t0 = at(7, 9)
        var record = JobRecord()
        record.start(at: t0)
        record.finish(.ok, at: t0, durationMS: 1, threshold: spec.breakerThreshold)
        func grade(after hours: Double) -> HealthGrade {
            let now = t0.addingTimeInterval(hours * 3600)
            return HealthGrade.job(record.heartbeatJob(spec: spec, now: now, wedged: false), key: "backup", startedAt: t0,
                                   lastWake: nil, now: now)
        }
        #expect(record.heartbeatJob(spec: spec, now: t0.addingTimeInterval(25 * 3600), wedged: false).due_since != nil)
        #expect(grade(after: 47) == .green)
        #expect(grade(after: 49) == .amber)
        #expect(grade(after: 7 * 24 + 1) == .red)
    }

    @Test func everyScheduledJobHasASpec() {
        for key in Scheduler.order { #expect(Scheduler.specs[key] != nil, "\(key)") }
        for key in Scheduler.intervals.keys { #expect(Scheduler.order.contains(key), "\(key)") }
    }
}
