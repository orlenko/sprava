import Darwin
import Foundation
import IOKit.pwr_mgt
import Services
import SpravaKit

/// The runtime's own health (architecture 3.3): the heartbeat it writes, the watchdog that ends it when it hangs,
/// sleep and wake, and the signals that end it cleanly.
extension Runtime {
    // MARK: - Heartbeat, watchdog, sleep and wake (architecture 3.3)

    func beat() {
        let now = Date()
        tick &+= 1
        watch.beat(tick)
        records.jobs["heartbeat", default: JobRecord()].start(at: now)
        let started = DispatchTime.now()
        var outcome = JobOutcome.ok
        do {
            try StateFile.write(try heartbeat(now: now).encoded(), to: runtimeDir.appendingPathComponent(Heartbeat.fileName))
        } catch {
            outcome = .error(code: "write_failed", culprit: "\(error)")
        }
        finish("heartbeat", outcome, started: started)
    }

    func heartbeat(now: Date) -> Heartbeat {
        var jobs: [String: Heartbeat.Job] = [:]
        for (key, spec) in Scheduler.specs {
            var record = records.jobs[key] ?? JobRecord()
            if key == "heartbeat" { record.running = false }   // this beat is the one being written
            // Awake time, as the watchdog counts it: a job the Mac slept through is not wedged. A job with no budget
            // (backup) is never wedged by time; its own cutoff stops it when it makes no progress.
            let wedged = record.running && spec.budget.map { budget in
                watch.runningFor(key).map { $0 > max(budget, .seconds(1)) * 2 } ?? false
            } ?? false
            // Due times count from this start when a job has never run, so a fresh runtime is not overdue at once.
            jobs[key] = record.heartbeatJob(spec: spec, now: now, wedged: wedged, anchor: startedAt)
        }
        return Heartbeat(pid: getpid(), started_at: ISOTime.string(startedAt), beat_at: ISOTime.string(now),
                         last_wake_at: lastWake.map { ISOTime.string($0) }, build: Self.build, xpc_protocol: Self.xpcProtocol,
                         lease: .init(inode: lease.inode, duplicates_refused_today: refusalsToday),
                         restarts_today: max(0, restartsToday - 1), alerts: alerts, runtime_key: nil, stage_crashes: [:],
                         model: model, outbound_today: [:], jobs: jobs)
    }

    /// A thread of its own reads the tick on a clock that stops while the Mac sleeps; `Watchdog.verdict` decides.
    func startWatchdog() {
        let thread = Thread { [weak self] in
            let clock = SuspendingClock()
            var lastTick: UInt64 = 0
            var lastChange = clock.now
            while let self {
                Thread.sleep(forTimeInterval: 60)
                // Read through the lock-protected box, never the state queue, which may be what hung.
                let (tick, wedged) = watch.read()
                if tick != lastTick { lastTick = tick; lastChange = clock.now }
                switch Watchdog.verdict(sinceTickMoved: lastChange.duration(to: clock.now), wedged: wedged) {
                case .fine: continue
                case .stalled:
                    log("watchdog stalled exit=\(Watchdog.exitStatus)")
                case .wedged(let job):
                    JobRecords.recordWatchdogExit(job: job, threshold: Scheduler.specs[job]?.breakerThreshold ?? 3,
                                                  url: breakersURL)
                    log("watchdog wedged job=\(job) exit=\(Watchdog.exitStatus)")
                }
                exit(Watchdog.exitStatus)
            }
        }
        thread.name = "sprava.watchdog"
        thread.start()
    }

    /// IOKit power notifications (spike i): sleep is allowed at once; a wake beats and catches up.
    func startPowerNotifications() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &powerPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let runtime = Unmanaged<Runtime>.fromOpaque(refcon).takeUnretainedValue()
            switch messageType {
            case 0xE000_0270, 0xE000_0280:   // kIOMessageCanSystemSleep, kIOMessageSystemWillSleep
                IOAllowPowerChange(runtime.rootPort, Int(bitPattern: argument))
            case 0xE000_0300:   // kIOMessageSystemHasPoweredOn
                runtime.queue.async { runtime.woke() }
            default:
                break
            }
        }, &notifier)
        if let powerPort { IONotificationPortSetDispatchQueue(powerPort, queue) } else { log("power_notifications unavailable") }
    }

    func woke() {
        lastWake = Date()
        log("wake")
        beat()
        scheduler.woke(now: Date())
    }

    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in
                if let self {
                    log("exit reason=signal_\(sig)")
                    try? records.save(breakersURL)
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
