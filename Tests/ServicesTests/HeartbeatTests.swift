import Foundation
@testable import Services
import SpravaKit
import Testing

/// `runtime/heartbeat.json` (architecture Appendix A) and how the app grades the runtime and its jobs from it.
/// Every value is invented.
@Suite struct HeartbeatTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-heartbeat-\(UUID().uuidString)")
        try AtomicFile.makePrivateFolder(dir)
        return dir
    }

    func beat() -> Heartbeat {
        Heartbeat(pid: 42, started_at: "2026-10-06T02:58:11+02:00", beat_at: "2026-10-06T07:12:41+02:00",
                  last_wake_at: nil, build: "0.1.0 (2)", xpc_protocol: 1,
                  lease: .init(inode: 9, duplicates_refused_today: 0), restarts_today: 0, alerts: nil,
                  runtime_key: nil, stage_crashes: [:], model: nil, outbound_today: [:],
                  jobs: ["backup:b2": Heartbeat.Job(last_outcome: "skipped", expected_cadence_s: 86_400)])
    }

    @Test func roundTripsAndRejectsBadValues() throws {
        let url = try folder().appendingPathComponent(Heartbeat.fileName)
        var beat = beat()
        try AtomicFile.write(try beat.encoded(), to: url)
        #expect(try Heartbeat.read(url).get() == beat)
        // The schema requires these keys even when empty.
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

    @Test func impossibleValuesAreUnreadableNeverGreen() throws {
        let url = try folder().appendingPathComponent(Heartbeat.fileName)
        let changes: [(inout Heartbeat) -> Void] = [
            { $0.format_version = "1" }, { $0.pid = 0 }, { $0.xpc_protocol = 0 }, { $0.build = "" },
            { $0.lease.inode = 0 }, { $0.lease.duplicates_refused_today = -1 }, { $0.beat_at = "yesterday" },
            { $0.runtime_key = "lost" }, { $0.jobs["hub"] = Heartbeat.Job(last_outcome: "fine") },
            { $0.jobs["hub"] = Heartbeat.Job(breaker: "ajar") }, { $0.jobs["hub"] = Heartbeat.Job(consecutive_failures: -1) },
            { $0.jobs["hub"] = Heartbeat.Job(last_error: .init(at: "2026-10-06T07:12:41+02:00", code: "Not A Code")) },
            { $0.jobs["hub"] = Heartbeat.Job(last_error: .init(at: "2026-10-06T07:12:41+02:00", code: "x",
                                                                culprit: String(repeating: "a", count: 201))) },
            { $0.jobs["hub"] = Heartbeat.Job(expected_cadence_s: 0) },
            { $0.last_wake_at = "this morning" }, { $0.restarts_today = -1 },
            { $0.alerts = .init(authorized: true, checked_at: "soon") }, { $0.stage_crashes = ["Extract": 0] },
            { $0.stage_crashes = ["extract": -1] }, { $0.model = .init(availability: "broken") },
            { $0.model = .init(availability: "available", context_size: 0) },
            { $0.model = .init(availability: "available", last_success: "never") },
            { $0.model = .init(availability: "available", errors_24h: ["rateLimited": -1]) },
            { $0.outbound_today = ["backup_bytes": -1] },
            { $0.jobs["hub"] = Heartbeat.Job(last_success: "yesterday") },
            { $0.jobs["hub"] = Heartbeat.Job(last_start: "2026-13-40") },
            { $0.jobs["hub"] = Heartbeat.Job(due_since: "late") },
            { $0.jobs["hub"] = Heartbeat.Job(last_error: .init(at: "then", code: "x")) },
            { $0.jobs["hub"] = Heartbeat.Job(watchdog_exits: -1) },
        ]
        for (index, change) in changes.enumerated() {
            var beat = beat()
            change(&beat)
            try AtomicFile.write(try beat.encoded(), to: url)
            #expect(Heartbeat.read(url) == .failure(.invalid), "change \(index)")
        }
    }

    @Test func aJobWithoutAKeyTheSchemaRequiresIsUnreadable() throws {
        let url = try folder().appendingPathComponent(Heartbeat.fileName)
        let encoded = try JSONSerialization.jsonObject(with: try beat().encoded()) as! [String: Any]
        for key in Heartbeat.Job.requiredKeys.map(\.stringValue) {
            var object = encoded, jobs = object["jobs"] as! [String: Any], job = jobs["backup:b2"] as! [String: Any]
            job[key] = nil
            jobs["backup:b2"] = job
            object["jobs"] = jobs
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            #expect(Heartbeat.read(url) == .failure(.invalid), "without \(key)")
        }
        // Present as null is what the schema asks for, and reads.
        try JSONSerialization.data(withJSONObject: encoded).write(to: url)
        #expect(try Heartbeat.read(url).get() == beat())
    }

    @Test func aLinkOrAnotherKindOfFileIsUnreadableNotMissing() throws {
        let dir = try folder()
        let real = dir.appendingPathComponent("elsewhere.json"), url = dir.appendingPathComponent(Heartbeat.fileName)
        try AtomicFile.write(try beat().encoded(), to: real)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: real)
        #expect(Heartbeat.read(url) == .failure(.invalid))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(Heartbeat.read(url) == .failure(.invalid))
    }

    @Test func theBeatIsGradedByItsAgeAndTheLastWake() {
        #expect(HealthGrade.beat(now.addingTimeInterval(-60), lastWake: nil, now: now, pidAlive: true) == .green)
        #expect(HealthGrade.beat(now.addingTimeInterval(-150), lastWake: nil, now: now, pidAlive: true) == .amber)
        #expect(HealthGrade.beat(now.addingTimeInterval(-301), lastWake: nil, now: now, pidAlive: true) == .red)
        #expect(HealthGrade.beat(now.addingTimeInterval(-10), lastWake: nil, now: now, pidAlive: false) == .red)
        // A night of sleep: the beat is 8 hours old but the Mac woke 20 seconds ago.
        #expect(HealthGrade.beat(now.addingTimeInterval(-28_800), lastWake: now.addingTimeInterval(-20), now: now,
                                 pidAlive: true) == .waking)
        // The runtime beat at once on the wake: still "waking up" for the first minute, as specified.
        #expect(HealthGrade.beat(now.addingTimeInterval(-5), lastWake: now.addingTimeInterval(-20), now: now,
                                 pidAlive: true) == .waking)
        // Woke 3 minutes ago and still no beat: amber.
        #expect(HealthGrade.beat(now.addingTimeInterval(-28_800), lastWake: now.addingTimeInterval(-180), now: now,
                                 pidAlive: true) == .amber)
    }

    @Test func aJobIsGradedByItsCadenceBreakerAndFailures() {
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
        // So does a run that found nothing set up to do.
        job.last_idle = ISOTime.string(now.addingTimeInterval(-60))
        #expect(HealthGrade.job(job, startedAt: started, lastWake: nil, now: now) == .green)
        job.consecutive_failures = 1
        #expect(HealthGrade.job(job, startedAt: started, lastWake: nil, now: now) == .amber)
        job.wedged = true
        #expect(HealthGrade.job(job, startedAt: started, lastWake: nil, now: now) == .red)
        job.wedged = false
        job.breaker = "open"
        #expect(HealthGrade.job(job, startedAt: started, lastWake: nil, now: now) == .red)
    }
}
