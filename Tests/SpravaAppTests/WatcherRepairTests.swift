import Foundation
import Services
@testable import SpravaApp
import SpravaKit
import Testing

/// After a change of signer, launchd refused the outside watcher on every run, and nothing registered it again: the
/// watcher was silently off until the person ran a manual repair (issue #523). Health now registers it again once the
/// runtime is live and the watcher has missed two runs. Stand-in repairs only; nothing reaches launchd.
@MainActor
@Suite struct WatcherRepairTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    func due(ranAt: Date?, started: Date? = nil, wake: Date? = nil, attempt: Date? = nil,
             live: Bool = true, enabled: Bool = true) -> Bool {
        WatcherRepair.due(watchRanAt: ranAt, runtimeStartedAt: started ?? ago(240), lastWake: wake, lastAttempt: attempt,
                          runtimeLive: live, watcherEnabled: enabled, now: now)
    }

    @Test func aWatcherThatMissedTwoRunsUnderALiveRuntimeIsRegisteredAgain() {
        #expect(due(ranAt: ago(40)))
        #expect(!due(ranAt: ago(20)))
        // Never ran since a registration well before: due too.
        #expect(due(ranAt: nil))
    }

    @Test func aFreshStartOrAWakeGetsItsTwoRunsFirst() {
        #expect(!due(ranAt: nil, started: ago(10)))
        #expect(!due(ranAt: ago(240), started: ago(240), wake: ago(10)))
    }

    @Test func nothingIsDoneWithoutALiveRuntimeOrARegisteredWatcher() {
        #expect(!due(ranAt: ago(40), live: false))
        // Waiting for approval in Login Items, or not registered: the keeper or the person handles that.
        #expect(!due(ranAt: ago(40), enabled: false))
    }

    @Test func oneAttemptAnHourAtMost() {
        #expect(!due(ranAt: ago(240), attempt: ago(30)))
        #expect(due(ranAt: ago(240), attempt: ago(61)))
    }

    @Test func theWatchersRecordIsReadAsItWritesIt() {
        #expect(WatcherRepair.ranAt(#"{"ran_at":"2026-10-30T11:30:04-04:00","saw":"ok","beat_age_s":29}"#)
                == ISOTime.date("2026-10-30T11:30:04-04:00"))
        #expect(WatcherRepair.ranAt(nil) == nil)
        #expect(WatcherRepair.ranAt("not json") == nil)
    }

    final class Repairs: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var made: Int { lock.withLock { count } }
        func repair() -> String? { lock.withLock { count += 1 }; return nil }
    }

    @Test func healthRegistersTheWatcherAgainOnceWhenItIsDue() async throws {
        let repairs = Repairs()
        // A live runtime: this test process, beating an hour from now, when the watcher last ran 45 minutes before.
        let later = Date().addingTimeInterval(3600)
        var heartbeat = Heartbeat(pid: getpid(), started_at: "", beat_at: ISOTime.string(later), last_wake_at: nil,
                                  build: "dev", xpc_protocol: 1, lease: .init(inode: 9, duplicates_refused_today: 0),
                                  restarts_today: 0, alerts: nil, runtime_key: nil, stage_crashes: [:], model: nil,
                                  outbound_today: [:], jobs: [:])
        heartbeat.started_at = ISOTime.string(try #require(ProcessCheck.startTime(pid: getpid())))
        var records = HealthSnapshot.Runtime()
        records.heartbeat = .success(heartbeat)
        records.watchRecord = #"{"ran_at":"\#(ISOTime.string(later.addingTimeInterval(-45 * 60)))","saw":"ok"}"#
        let snapshot = records
        var reads = HealthModel.Reads()
        reads.runtime = { _ in snapshot }
        reads.checks = { _ in HealthSnapshot.Checks() }
        reads.repairWatcher = { repairs.repair() }
        let model = HealthModel(support: try temporaryFolder(), reads: reads)
        model.refresh()
        await model.settled()
        model.runtimeStatus = .enabled
        model.watchStatus = .enabled
        model.now = later
        #expect(model.beatGrade == .green)
        model.repairWatcherIfDue()
        await model.settled()
        #expect(repairs.made == 1 && model.watcherRepairFailure == nil)
        // Within the hour nothing is tried again, however often Health reads.
        model.repairWatcherIfDue()
        await model.settled()
        #expect(repairs.made == 1)
    }
}
