import AppKit
import Foundation
@testable import Services
@testable import SpravaApp
import SpravaKit
import SwiftUI
import Testing

/// Health in plain words (decisions.md D37): job rows by what they do, what is wrong and what to do, the notice first with
/// its existing buttons, and the code words kept whole under Details for support. Invented data and temporary folders only.
@MainActor
@Suite(.serialized) struct HealthWordsTests {
    static let now = Date(timeIntervalSince1970: 1_793_800_000)

    func job(_ change: (inout Heartbeat.Job) -> Void = { _ in }) -> Heartbeat.Job {
        var job = Heartbeat.Job(last_start: ISOTime.string(Self.now.addingTimeInterval(-26 * 60)),
                                last_success: ISOTime.string(Self.now.addingTimeInterval(-26 * 60)), last_outcome: "ok",
                                expected_cadence_s: 3600, median_ms: 12, slowest_of_twenty_ms: 40)
        change(&job)
        return job
    }

    @Test func jobsAreNamedByWhatTheyDo() {
        for key in Scheduler.order { #expect(JobWords.names[key] != nil, "\(key) has no plain name") }
        #expect(JobWords.name("intake") == "Reading new documents on this Mac")
        #expect(JobWords.name("sentinel") == "Checking deadlines")
        // A job this app does not know yet is still shown, by its key.
        #expect(JobWords.name("invented_job") == "invented job")
    }

    @Test func aWellJobSaysOnlyWhenItLastRan() {
        let words = JobWords.of(job(), key: "intake", grade: .green, now: Self.now)
        #expect(words.lastRan.hasPrefix("last ran ") && words.lastRan.contains("26"))
        #expect(words.problem == nil && !words.restartHelps)
        #expect(JobWords.of(job { $0.last_outcome = "running" }, key: "intake", grade: .green, now: Self.now).lastRan == "running now")
        let never = job { $0.last_start = nil; $0.last_success = nil; $0.last_outcome = "none" }
        #expect(JobWords.of(never, key: "intake", grade: .green, now: Self.now).lastRan == "has not run yet")
    }

    @Test func aFailingJobSaysWhatIsWrongAndWhatToDo() throws {
        // Paused: restarting does not clear a breaker, so it offers no button and says there is nothing to do in the app.
        let paused = JobWords.of(job { $0.breaker = "open"; $0.consecutive_failures = 3 }, key: "hub", grade: .red, now: Self.now)
        #expect(!paused.restartHelps)
        #expect(try #require(paused.problem).contains("nothing to do in the app"))
        // Stuck or overdue: restarting the background part is the fix, beside the row.
        #expect(JobWords.of(job { $0.wedged = true }, key: "hub", grade: .red, now: Self.now).restartHelps)
        let overdue = JobWords.of(job(), key: "hub", grade: .amber, now: Self.now)
        #expect(overdue.restartHelps && overdue.problem?.contains("Restarting") == true)
        // One failed run: Sprava tries again by itself.
        let failed = JobWords.of(job { $0.last_outcome = "timeout"; $0.consecutive_failures = 1 }, key: "hub", grade: .amber, now: Self.now)
        #expect(!failed.restartHelps && failed.problem?.hasPrefix("The last run took too long.") == true)
    }

    @Test func supportDetailsKeepEveryCodeWord() {
        var beat = Self.beat()
        beat.lease.duplicates_refused_today = 2
        beat.jobs["hub"] = job {
            $0.breaker = "half_open"; $0.consecutive_failures = 2
            $0.last_error = .init(at: ISOTime.string(Self.now), code: "spool", culprit: "invented culprit")
        }
        let text = SupportDetails.text(heartbeat: .success(beat), registration: "enabled", startsToday: 4,
                                       refusals: ["invented refusal"], watchRecord: "invented watch record")
        for words in ["pid \(getpid())", "build 0.1.0 (7)", "restarts today 3", "duplicate starts refused 2", "Registration: enabled",
                      "hub: ok", "breaker half-open", "failures in a row 2", "spool: invented culprit", "median 12 ms · slowest 40 ms",
                      "Model: available · context 4096 tokens", "Outside watcher: invented watch record", "Refused: invented refusal"] {
            #expect(text.contains(words), "missing \(words)")
        }
        #expect(SupportDetails.text(heartbeat: .failure(.invalid), registration: "not found", startsToday: 0, refusals: [],
                                    watchRecord: nil) == "Registration: not found\nHeartbeat: unreadable")
    }

    @Test func theNoticeOffersTheButtonsItAlwaysHad() async throws {
        let model = try await Self.model(Self.beat())
        #expect(model.notice == nil)
        model.runtimeStatus = .requiresApproval
        let approval = try #require(model.notice)
        #expect(approval.level == .needsYou && approval.loginItems && !approval.restart)
        model.runtimeStatus = .enabled
        // A paused job is trouble, and restarting is not what helps it.
        var beat = Self.beat()
        beat.jobs["hub"] = job { $0.breaker = "open"; $0.consecutive_failures = 3 }
        model.heartbeat = .success(beat)
        let trouble = try #require(model.notice)
        #expect(trouble.level == .broken && !trouble.restart && trouble.title == "One of Sprava's background jobs has stopped working.")
    }

    /// The page in each state, light and dark. With SPRAVA_RENDER_ARTIFACTS_DIR set, it saves what it drew.
    @Test func eachStateOfThePageLaysOut() async throws {
        let well = try await Self.model(Self.beat())
        well.backupConfigured = true
        well.backups = [.init(name: "Instrument workshop", at: Self.now.addingTimeInterval(-7200), error: nil)]
        try await render(well, "well")

        var beat = Self.beat()
        beat.jobs["hub"] = job { $0.breaker = "open"; $0.consecutive_failures = 3
            $0.last_error = .init(at: ISOTime.string(Self.now), code: "spool", culprit: nil) }
        beat.jobs["dashboard"] = job { $0.wedged = true; $0.last_outcome = "running" }
        beat.alerts = .init(authorized: false, checked_at: ISOTime.string(Self.now))
        let trouble = try await Self.model(beat)
        trouble.backupConfigured = true
        trouble.backups = [.init(name: "Garden", at: nil, error: "The backup folder could not be written.")]
        trouble.findings = [.init(level: .fix, binder: "Boat", text: "the manual lacks Sprava's addendum; paste it from the binder's page")]
        trouble.supportOpen = true
        try await render(trouble, "trouble")
    }

    func render(_ model: HealthModel, _ name: String) async throws {
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: HealthView(model: model)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900), styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            for _ in 0..<8 {
                // The page reads on appear; the invented state stands, with the runtime registered.
                await model.settled()
                model.runtimeStatus = .enabled
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(host.fittingSize.width <= 720)
            if let directory = ProcessInfo.processInfo.environment["SPRAVA_RENDER_ARTIFACTS_DIR"] {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    destination.appendingPathComponent("health-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
            window.contentView = nil
        }
    }

    /// A live heartbeat of this test process, so the runtime reads as running; nothing is registered with launchd.
    static func beat() -> Heartbeat {
        let started = ProcessCheck.startTime(pid: getpid()) ?? now.addingTimeInterval(-3600)
        var jobs: [String: Heartbeat.Job] = [:]
        for key in ["capture", "intake", "sentinel", "hub", "dashboard"] {
            jobs[key] = Heartbeat.Job(last_start: ISOTime.string(Date().addingTimeInterval(-60)),
                                      last_success: ISOTime.string(Date().addingTimeInterval(-60)), last_outcome: "ok",
                                      median_ms: 12, slowest_of_twenty_ms: 40)
        }
        return Heartbeat(pid: getpid(), started_at: ISOTime.string(started), beat_at: ISOTime.string(Date()), last_wake_at: nil,
                         build: "0.1.0 (7)", xpc_protocol: 1, lease: .init(inode: 9, duplicates_refused_today: 0), restarts_today: 3,
                         alerts: .init(authorized: true, checked_at: ISOTime.string(Date())), runtime_key: nil, stage_crashes: [:],
                         model: .init(availability: "available", context_size: 4096), outbound_today: [:], jobs: jobs)
    }

    static func model(_ beat: Heartbeat) async throws -> HealthModel {
        var records = HealthSnapshot.Runtime()
        records.heartbeat = .success(beat)
        let snapshot = records
        var reads = HealthModel.Reads()
        reads.runtime = { _ in snapshot }
        reads.checks = { _ in HealthSnapshot.Checks() }
        reads.repairWatcher = { nil }
        let model = HealthModel(support: try temporaryFolder(), reads: reads)
        model.refresh()
        await model.settled()
        model.runtimeStatus = .enabled
        return model
    }
}
