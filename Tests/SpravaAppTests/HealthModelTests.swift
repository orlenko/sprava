import Combine
import Foundation
import Services
@testable import SpravaApp
import SpravaKit
import Testing

/// The Health page's model reads Services' health snapshot in the app's own process, so it tells a stopped runtime
/// from a quiet one without talking to it. Temporary support folders only; nothing is registered with launchd.
@MainActor
@Suite struct HealthModelTests {
    func beat(pid: Int32, at: Date) -> Heartbeat {
        Heartbeat(pid: pid, started_at: ISOTime.string(at.addingTimeInterval(-3600)), beat_at: ISOTime.string(at), last_wake_at: nil,
                  build: "0.1.0 (2)", xpc_protocol: 1, lease: .init(inode: 9, duplicates_refused_today: 0), restarts_today: 0,
                  alerts: nil, runtime_key: nil, stage_crashes: [:], model: nil, outbound_today: [:], jobs: [:])
    }

    @Test func theRuntimesOwnRecordsAreShown() async throws {
        let support = try temporaryFolder()
        let runtime = HealthSnapshot.runtimeDirectory(support: support)
        try AtomicFile.makePrivateFolder(runtime)
        let model = HealthModel(support: support)
        model.refresh()
        await model.settled()
        #expect(model.heartbeat == .failure(.missing) && !model.backgroundOffByChoice)
        // Not registered and no heartbeat: unknown, not red.
        #expect(model.beatGrade == .unknown)
        try Data().write(to: runtime.appendingPathComponent("background-off"))
        var state = RuntimeState()
        state.day = CalendarDate.today().description
        state.startsToday = 2
        try JSONEncoder().encode(state).write(to: RuntimeState.url(runtime))
        model.refresh()
        await model.settled()
        #expect(model.backgroundOffByChoice && model.startsToday == 2)
    }

    @Test func aHeartbeatFromAProcessThatIsGoneIsRed() async throws {
        let support = try temporaryFolder()
        let runtime = HealthSnapshot.runtimeDirectory(support: support)
        try AtomicFile.makePrivateFolder(runtime)
        // A pid no process holds: the beat is fresh but nobody is beating.
        try beat(pid: Int32.max - 1, at: Date()).encoded().write(to: runtime.appendingPathComponent(Heartbeat.fileName))
        let model = HealthModel(support: support)
        model.refresh()
        await model.settled()
        #expect(model.beatGrade == .red)
        // Right after a start request, with no newer beat, the page says "starting" instead.
        model.startRequested = Date().addingTimeInterval(1)
        #expect(model.starting && model.beatGrade == .unknown)
    }

    /// A read that waits until the test lets it go, standing in for a binder whose files block (a FIFO) or a slow disk.
    final class Gate: @unchecked Sendable {
        let open = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func enter() -> Int {
            let n = lock.withLock { count += 1; return count }
            open.wait()
            return n
        }
        func release(_ times: Int = 1) { for _ in 0..<times { open.signal() } }
    }

    @Test func aSlowCheckDoesNotHoldTheMainActor() async throws {
        let gate = Gate()
        var reads = HealthModel.Reads()
        reads.checks = { _ in
            _ = gate.enter()
            var checks = HealthSnapshot.Checks()
            checks.backupConfigured = true
            return checks
        }
        let model = HealthModel(support: try temporaryFolder(), reads: reads)
        let started = Date()
        model.refresh()
        // Control is back on the main actor while the doctor is still stuck.
        #expect(Date().timeIntervalSince(started) < 1)
        while gate.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.backupConfigured)
        // A refresh while it is stuck does not start a second one.
        model.lastDoctor = .distantPast
        model.refresh()
        try await Task.sleep(for: .milliseconds(50))
        #expect(gate.calls == 1)
        gate.release()
        await model.settled()
        #expect(model.backupConfigured && gate.calls == 1)
    }

    @Test func aRuntimeReadOvertakenByANewerRefreshIsDroppedAndReadAgain() async throws {
        let gate = Gate()
        var reads = HealthModel.Reads()
        reads.runtime = { _ in
            var records = HealthSnapshot.Runtime()
            records.startsToday = gate.enter()
            return records
        }
        reads.checks = { _ in HealthSnapshot.Checks() }
        let model = HealthModel(support: try temporaryFolder(), reads: reads)
        var published: [Int] = []
        let watch = model.$startsToday.dropFirst().sink { published.append($0) }
        defer { watch.cancel() }
        model.refresh()
        while gate.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        // Two more refreshes while the first read is stuck: no second read starts yet.
        model.refresh()
        model.refresh()
        #expect(gate.calls == 1)
        gate.release(2)
        await model.settled()
        // The first read's result began before the newer refreshes, so only the second read's is published.
        #expect(gate.calls == 2 && published == [2])
    }
}
