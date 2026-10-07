import Foundation
import Testing
@testable import SpravaCore

@Suite struct BreakerTests {
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

    @Test func skippedIsNeverASuccess() {
        var r = JobRecord()
        r.start(at: t0)
        r.finish(.skipped, at: t0, durationMS: 1, threshold: 3)
        #expect(r.lastOutcome == "skipped")
        #expect(r.lastSuccess == nil)
    }

    @Test func keepsTwentyDurations() {
        var r = JobRecord()
        for i in 1...25 { r.finish(.ok, at: t0, durationMS: i, threshold: 3) }
        #expect(r.durationsMS.count == 20)
        #expect(r.medianMS == 16)
        #expect(r.durationsMS.max() == 25)
    }

    @Test func recordsSurviveARoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-\(UUID().uuidString)")
        try AtomicFile.makePrivateFolder(dir)
        var records = JobRecords()
        var r = JobRecord()
        r.start(at: t0)
        r.finish(.error(code: "x", culprit: "y"), at: t0, durationMS: 3, threshold: 1)
        r.watchdogExits = 2
        r.running = true
        records.jobs["sentinel"] = r
        try records.save(dir.appendingPathComponent("breakers.json"))
        let loaded = JobRecords.load(dir.appendingPathComponent("breakers.json"))
        #expect(loaded.jobs["sentinel"]?.breaker == "open")
        #expect(loaded.jobs["sentinel"]?.watchdogExits == 2)
        #expect(loaded.jobs["sentinel"]?.running == false)
    }
}

@Suite struct HealthGradeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func beatAge() {
        #expect(HealthGrade.beat(now.addingTimeInterval(-60), lastWake: nil, now: now, pidAlive: true) == .green)
        #expect(HealthGrade.beat(now.addingTimeInterval(-150), lastWake: nil, now: now, pidAlive: true) == .amber)
        #expect(HealthGrade.beat(now.addingTimeInterval(-301), lastWake: nil, now: now, pidAlive: true) == .red)
        #expect(HealthGrade.beat(now.addingTimeInterval(-10), lastWake: nil, now: now, pidAlive: false) == .red)
        // A night of sleep: the beat is 8 hours old but the Mac woke 20 seconds ago.
        #expect(HealthGrade.beat(now.addingTimeInterval(-28_800), lastWake: now.addingTimeInterval(-20), now: now,
                                 pidAlive: true) == .waking)
        // Woke 3 minutes ago and still no beat: amber.
        #expect(HealthGrade.beat(now.addingTimeInterval(-28_800), lastWake: now.addingTimeInterval(-180), now: now,
                                 pidAlive: true) == .amber)
    }

    @Test func jobCadence() {
        var job = Heartbeat.Job(last_success: ISOTime.string(now.addingTimeInterval(-3000)), last_outcome: "ok",
                                expected_cadence_s: 3600)
        let started = now.addingTimeInterval(-100_000)
        #expect(HealthGrade.job(job, startedAt: started, lastWake: nil, now: now) == .green)
        job.last_success = ISOTime.string(now.addingTimeInterval(-3 * 3600))
        #expect(HealthGrade.job(job, startedAt: started, lastWake: nil, now: now) == .amber)
        job.last_success = ISOTime.string(now.addingTimeInterval(-5 * 3600))
        #expect(HealthGrade.job(job, startedAt: started, lastWake: nil, now: now) == .red)
        // A wake resets the clock: the lid was closed all week.
        #expect(HealthGrade.job(job, startedAt: started, lastWake: now.addingTimeInterval(-60), now: now) == .green)
        job.breaker = "open"
        #expect(HealthGrade.job(job, startedAt: started, lastWake: nil, now: now) == .red)
    }
}

@Suite struct LeaseAndHeartbeatTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-\(UUID().uuidString)")
        try AtomicFile.makePrivateFolder(dir)
        return dir
    }

    @Test func secondLeaseIsRefusedAndReleasedOnClose() throws {
        let url = try tempDir().appendingPathComponent("lease")
        guard case .acquired(let first) = try Lease.acquire(at: url) else {
            Issue.record("first lease must be acquired")
            return
        }
        guard case .held(let pid) = try Lease.acquire(at: url) else {
            Issue.record("second lease must be refused")
            return
        }
        #expect(pid == getpid())
        #expect(first.inode > 0)
        _ = consume first
        guard case .acquired = try Lease.acquire(at: url) else {
            Issue.record("the lease must be free once released")
            return
        }
    }

    @Test func heartbeatRoundTripsAndRejectsBadValues() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent(Heartbeat.fileName)
        var beat = Heartbeat(pid: 42, started_at: "2026-10-06T02:58:11+02:00", beat_at: "2026-10-06T07:12:41+02:00",
                             last_wake_at: nil, build: "0.1.0 (2)", xpc_protocol: 1,
                             lease: .init(inode: 9, duplicates_refused_today: 0), restarts_today: 0, alerts: nil,
                             runtime_key: nil, stage_crashes: [:], model: nil, outbound_today: [:],
                             jobs: ["backup:b2": Heartbeat.Job(last_outcome: "skipped", expected_cadence_s: 86_400)])
        try AtomicFile.write(try beat.encoded(), to: url)
        #expect(try Heartbeat.read(url).get() == beat)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(text.contains("\"last_success\" : null"))

        beat.jobs["Bad Key"] = Heartbeat.Job()
        try AtomicFile.write(try beat.encoded(), to: url)
        #expect(Heartbeat.read(url) == .failure(.invalid))
        try Data("{\"pid\": 1}".utf8).write(to: url)
        #expect(Heartbeat.read(url) == .failure(.invalid))
        try FileManager.default.removeItem(at: url)
        #expect(Heartbeat.read(url) == .failure(.missing))
    }

    @Test func atomicWriteLeavesNoTempFiles() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("x.json")
        for i in 0..<5 { try AtomicFile.write(Data("\(i)".utf8), to: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "4")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["x.json"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func logRotation() throws {
        let url = try tempDir().appendingPathComponent("jobs.log")
        for i in 0..<50 { AtomicFile.appendLine("line \(i) " + String(repeating: "x", count: 30), to: url, limit: 200, keep: 3) }
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
        #expect(files == ["jobs.log", "jobs.log.1", "jobs.log.2", "jobs.log.3"])
    }

    @Test func processCheckRecognisesThisProcess() {
        let start = ProcessCheck.startTime(pid: getpid())
        #expect(start != nil)
        #expect(ProcessCheck.isAlive(pid: getpid(), startedAt: start))
        #expect(!ProcessCheck.isAlive(pid: getpid(), startedAt: start!.addingTimeInterval(-3600)))
        #expect(!ProcessCheck.isAlive(pid: 999_999, startedAt: nil))
    }
}

@Suite struct SentinelTests {
    @Test func countsUnderOpaqueIDsWithNoTitles() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        let rows = Shelf.rows(registry: nil, picked: [folder])
        var ids = BinderIDs()
        let report = SentinelReport.compute(rows: rows, ids: &ids, today: today, now: Date(), timeZone: utc)
        #expect(report.binders["b1"] == SentinelReport.Counts(state: "ready", overdue: 0, today: 0, nudge: 1, next7: 1))
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains("estate"))
        #expect(!json.contains("notary"))
        #expect(report.summaryText == "1 to follow up")
        let first = ids.id(for: folder)
        #expect(first == "b1")
        let second = ids.id(for: folder.appendingPathComponent("../other"))
        #expect(second == "b2")
    }

    @Test func nextClockTimeRollsToTomorrow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let morning = cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 7, minute: 59))!
        let after = cal.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 8, minute: 0))!
        #expect(nextClockTime(hour: 8, minute: 0, after: morning, calendar: cal) == after)
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 8, minute: 0))!
        #expect(nextClockTime(hour: 8, minute: 0, after: after, calendar: cal) == tomorrow)
    }
}
