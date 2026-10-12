import Foundation
@testable import Services
import SpravaKit
import Testing

/// A job's breaker, failures and durations (architecture 3.4, 3.5), and how a record reads in the heartbeat.
@Suite struct JobRecordTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func opensAfterThresholdAndBacksOff() {
        var r = JobRecord()
        for i in 0..<3 {
            let ok = r.mayRun(now: t0)
            #expect(ok)
            r.start(at: t0)
            r.finish(.error(code: "boom", culprit: nil), at: t0.addingTimeInterval(Double(i)), durationMS: 5, threshold: 3)
        }
        #expect(r.breaker == "open")
        #expect(r.consecutiveFailures == 3)
        do { let ok = r.mayRun(now: t0.addingTimeInterval(30)); #expect(!ok) }
        // After the first backoff (1 minute) one trial runs half-open; a failure reopens with the next step (5 min).
        do { let ok = r.mayRun(now: t0.addingTimeInterval(65)); #expect(ok) }
        #expect(r.breaker == "half_open")
        r.finish(.timeout, at: t0.addingTimeInterval(66), durationMS: 1000, threshold: 3)
        #expect(r.breaker == "open")
        #expect(r.backoffStep == 1)
        do { let ok = r.mayRun(now: t0.addingTimeInterval(66 + 120)); #expect(!ok) }
        do { let ok = r.mayRun(now: t0.addingTimeInterval(66 + 301)); #expect(ok) }
        r.finish(.ok, at: t0.addingTimeInterval(400), durationMS: 4, threshold: 3)
        #expect(r.breaker == "closed")
        #expect(r.consecutiveFailures == 0)
        #expect(r.backoffStep == 0)
    }

    @Test func skippedIsNeverASuccessAndLeavesAnOpenBreakerOpen() {
        var r = JobRecord()
        r.start(at: t0)
        r.finish(.skipped, at: t0, durationMS: 1, threshold: 3)
        #expect(r.lastOutcome == "skipped")
        #expect(r.lastSuccess == nil)
        r.finish(.error(code: "x", culprit: nil), at: t0, durationMS: 1, threshold: 1)
        #expect(r.breaker == "open")
        r.finish(.skipped, at: t0, durationMS: 1, threshold: 1)
        #expect(r.breaker == "open" && r.consecutiveFailures == 1)
    }

    @Test func keepsTwentyDurations() {
        var r = JobRecord()
        for i in 1...25 { r.finish(.ok, at: t0, durationMS: i, threshold: 3) }
        #expect(r.durationsMS.count == 20)
        #expect(r.medianMS == 16)
        #expect(r.durationsMS.max() == 25)
    }

    @Test func aStepOutOfRangeWaitsTheNearestBackoffInsteadOfCrashing() {
        var record = JobRecord()
        record.breaker = "open"
        record.breakerOpenedAt = t0
        record.backoffStep = -1
        let early = record.mayRun(now: t0.addingTimeInterval(30))
        let later = record.mayRun(now: t0.addingTimeInterval(61))
        #expect(!early && later)
    }

    @Test func idleRunsKeepAJobGreenAndSkippedRunsDoNot() {
        let spec = JobSpec(key: "hub", budget: .seconds(30), expectedCadence: 300, breakerThreshold: 3)
        var idle = JobRecord(), skipped = JobRecord()
        for i in 0...10 {
            let t = t0.addingTimeInterval(Double(i) * 300)
            idle.start(at: t); idle.finish(.idle, at: t, durationMS: 1, threshold: 3)
            skipped.start(at: t); skipped.finish(.skipped, at: t, durationMS: 1, threshold: 3)
        }
        let at = t0.addingTimeInterval(10 * 300 + 10)
        #expect(idle.lastSuccess == nil)
        #expect(HealthGrade.job(idle.heartbeatJob(spec: spec, now: at, wedged: false), startedAt: t0, lastWake: nil, now: at) == .green)
        #expect(HealthGrade.job(skipped.heartbeatJob(spec: spec, now: at, wedged: false), startedAt: t0, lastWake: nil, now: at) == .red)
        // The heartbeat still says "skipped", the schema's word.
        #expect(idle.heartbeatJob(spec: spec, now: at, wedged: false).last_outcome == "skipped")
    }

    @Test func aRunningJobAndItsDueTimeReachTheHeartbeat() {
        let spec = JobSpec(key: "hub", budget: .seconds(30), expectedCadence: 300, breakerThreshold: 3)
        var r = JobRecord()
        r.finish(.ok, at: t0, durationMS: 7, threshold: 3)
        r.start(at: t0.addingTimeInterval(400))
        let job = r.heartbeatJob(spec: spec, now: t0.addingTimeInterval(500), wedged: true)
        #expect(job.last_outcome == "running" && job.wedged)
        #expect(job.due_since == ISOTime.string(t0.addingTimeInterval(300)))
        #expect(job.median_ms == 7 && job.slowest_of_twenty_ms == 7)
        #expect(r.heartbeatJob(spec: spec, now: t0.addingTimeInterval(200), wedged: false).due_since == nil)
    }
}

/// What the watchdog reads: a job counts as wedged by awake time only.
@Suite struct WatchBoxTests {
    @Test func sleepDoesNotCountTowardsAWedge() {
        final class Clock: @unchecked Sendable { let lock = NSLock(); var awake: Duration = .zero }
        let clock = Clock()
        let box = WatchBox(budgets: ["backup": .seconds(3 * 3600)], awake: { clock.lock.lock(); defer { clock.lock.unlock() }; return clock.awake })
        box.started("backup")
        box.beat(7)
        // A night asleep moves the wall clock, not this one.
        #expect(box.read() == (7, nil))
        clock.lock.lock(); clock.awake = .seconds(6 * 3600 + 601); clock.lock.unlock()
        #expect(box.read().1 == "backup")
        #expect(box.runningFor("backup") == .seconds(6 * 3600 + 601))
        box.finished("backup")
        #expect(box.read().1 == nil && box.runningFor("backup") == nil)
    }
}
