import BinderStore
import Darwin
import Foundation
import IOKit.pwr_mgt
import Services
import Shelf
import SpravaKit

/// The supervised runtime (architecture section 3): one process, one lease, a heartbeat every 30 seconds, a
/// watchdog, and timed jobs with breakers. What runs when is the `Scheduler`'s to say and each job's body is a
/// function in `Services/Jobs`; this file holds the timers, the lease, the heartbeat, the watchdog, power and
/// clock events, and the wiring (docs/code-structure.md rule 8).
final class Runtime: @unchecked Sendable {
    static let build = "0.1.0 (2)"
    static let xpcProtocol = 1

    let support: URL
    let runtimeDir: URL
    /// The state queue: records, the scheduler and everything below are read and changed only here.
    let queue = DispatchQueue(label: "sprava.runtime.state")
    let startedAt = Date()
    let lease: Lease
    var records: JobRecords
    var scheduler: Scheduler
    var lastWake: Date?
    var tick: UInt64 = 0
    var alerts: Heartbeat.Alerts?
    var model: Heartbeat.Model?
    var refusalsToday = 0
    var restartsToday = 0
    var timeouts: [String: Date] = [:]   // job key -> when it overran
    var runGeneration: [String: Int] = [:]
    var timers: [DispatchSourceTimer] = []
    var signalSources: [DispatchSourceSignal] = []
    var breakersUnwritable = false
    var xpc: XPCService?
    var commands: Commands?
    /// Set when this Mac's device id cannot be read: nothing is written until it is repaired.
    var deviceIDError: String?
    /// The jobs' budgets and the app requests' (`RequestQueues`), so the watchdog names a request that hangs too.
    let watch = WatchBox(budgets: Scheduler.specs.mapValues(\.budget).merging(RequestQueues.budgets) { job, _ in job })
    /// Jobs run concurrently; the opaque binder id file is read, changed and written by one at a time.
    let idsLock = NSLock()

    var breakersURL: URL { runtimeDir.appendingPathComponent("breakers.json") }

    init(support: URL, lease: Lease) {
        self.support = support
        runtimeDir = support.appendingPathComponent("runtime", isDirectory: true)
        self.lease = lease
        let (loaded, setAside) = JobRecords.loadAtStart(runtimeDir.appendingPathComponent("breakers.json"),
                                                        jobs: Array(Scheduler.specs.keys))
        records = loaded
        let (state, stateSetAside) = RuntimeState.loadAtStart(runtimeDir)
        refusalsToday = state.refusalsToday
        restartsToday = state.startsToday
        scheduler = Scheduler(now: Date(), lastSummaryDate: state.lastSummaryDate, lastSentinelDate: state.lastSentinelDate)
        if let setAside { log("breakers_unreadable kept_as=\(setAside.lastPathComponent) breakers=half_open") }
        if let stateSetAside { log("runtime_state_unreadable kept_as=\(stateSetAside.lastPathComponent) summary_today=counted_as_sent") }
    }

    func log(_ line: String) {
        AtomicFile.appendLine("\(ISOTime.string(Date())) \(line)", to: runtimeDir.appendingPathComponent("jobs.log"))
    }

    // MARK: - Start

    func start() {
        log("start pid=\(getpid()) build=\(Self.build)")
        RuntimeState.recordStart(runtimeDir)
        installSignalHandlers()
        startTimer(every: 30, now: true) { [weak self] in self?.beat() }
        startWatchdog()
        startPowerNotifications()
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.clockChanged(reason: name == .NSSystemClockDidChange ? "clock" : "time_zone") }
            }
        }
        // The device id is read once. One that cannot be read is never replaced: every binder this Mac owns names
        // it. Without it there are no commands, so nothing is written.
        do {
            let commands = Commands(support: support, deviceID: try DeviceID.load(support: support))
            self.commands = commands
            let service = XPCService(commands: commands, watch: watch) { [weak self] line in self?.log(line) }
            service.start()
            xpc = service
        } catch {
            deviceIDError = "\(error)"
            log("device_id_unreadable writes=off")
        }
        startTimer(every: 15, now: false) { [weak self] in self?.schedule() }
    }

    func startTimer(every seconds: Int, now: Bool, _ handler: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + (now ? 0 : 1), repeating: .seconds(seconds))
        timer.setEventHandler(handler: handler)
        timer.resume()
        timers.append(timer)
    }

    func clockChanged(reason: String) {
        log("clock_changed reason=\(reason)")
        scheduler.clockChanged(now: Date())
    }

    // MARK: - Jobs (architecture 3.4)

    func schedule() {
        for key in scheduler.due(now: Date(), sentinelRunning: records.jobs["sentinel"]?.running == true) {
            if let body = body(for: key) { run(key, body) }
        }
    }

    /// The jobs this runtime runs so far; the others join with their areas.
    func body(for key: String) -> (@Sendable () -> JobOutcome)? {
        switch key {
        case "sentinel": { [unowned self] in sentinel() }
        case "summary": { [unowned self] in summary() }
        case "alerts": { [unowned self] in checkAlerts() }
        default: nil
        }
    }

    /// Runs a job off the state queue with its budget. An overrun is recorded as a timeout at once; the job is
    /// shown as wedged if it keeps running (architecture 3.4).
    func run(_ key: String, _ body: @escaping @Sendable () -> JobOutcome) {
        guard let spec = Scheduler.specs[key] else { return }
        let running = Set(records.jobs.compactMap { $0.value.running ? $0.key : nil })
        guard Scheduler.mayStart(key, running: running) else { return }
        let now = Date()
        var record = records.jobs[key] ?? JobRecord()
        guard !record.running, record.mayRun(now: now) else { return }
        record.start(at: now)
        records.jobs[key] = record
        scheduler.started(key, now: now)
        watch.started(key)
        runGeneration[key, default: 0] += 1
        let generation = runGeneration[key]!
        let started = DispatchTime.now()
        // A job with no budget (backup) has no deadline; its own cutoff stops it when it makes no progress.
        if let limit = spec.budget {
            let budget = Double(limit.components.seconds)
            queue.asyncAfter(deadline: .now() + budget) { [weak self] in
                // Only this run's timer counts: a timer left from an earlier run never marks a later one.
                guard let self, runGeneration[key] == generation, records.jobs[key]?.running == true, timeouts[key] == nil else { return }
                timeouts[key] = Date()
                log("job=\(key) outcome=timeout budget_s=\(Int(budget))")
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = body()
            self?.queue.async { self?.finish(key, outcome, started: started) }
        }
    }

    func finish(_ key: String, _ outcome: JobOutcome, started: DispatchTime) {
        watch.finished(key)
        let ms = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        let final = timeouts.removeValue(forKey: key) != nil ? JobOutcome.timeout : outcome
        let before = records.jobs[key]?.breaker
        records.jobs[key, default: JobRecord()].finish(final, at: Date(), durationMS: ms,
                                                       threshold: Scheduler.specs[key]?.breakerThreshold ?? 3)
        if key != "heartbeat" || final != .ok {
            var line = "job=\(key) outcome=\(records.jobs[key]?.lastOutcome ?? "?") ms=\(ms)"
            if case .error(let code, _) = final { line += " code=\(code)" }
            log(line)
        }
        if before != "open", records.jobs[key]?.breaker == "open" {
            log("breaker_open job=\(key)")
            notify(title: "Sprava", body: "A background job keeps failing. Open Sprava's Health page.", id: "breaker-\(key)")
        }
        // Kept in memory either way; a save that fails is logged once and tried again after the next job.
        do {
            try records.save(breakersURL)
            breakersUnwritable = false
        } catch {
            if !breakersUnwritable { log("breakers_unwritable") }
            breakersUnwritable = true
        }
    }

    func sentinel() -> JobOutcome {
        let support = support
        let (outcome, day) = SentinelJob.run(rows: { try ShelfStore(supportDirectory: support).rowsForJobs() }, support: support,
                                             runtimeDir: runtimeDir, idsLock: idsLock, now: Date())
        if let day {
            queue.async { [self] in
                scheduler.sentinelRan(day: day)
                RuntimeState.update(runtimeDir) { $0.lastSentinelDate = day }
            }
        }
        return outcome
    }

    func summary() -> JobOutcome {
        let runtimeDir = runtimeDir
        let today = CalendarDate.today().description
        let (lastSent, breaker) = queue.sync { (scheduler.lastSummaryDate, records.jobs["sentinel"]?.breaker) }
        let (outcome, sent) = SummaryJob.run(.init(
            today: today, lastSent: lastSent, report: { SentinelJob.report(runtimeDir: runtimeDir, today: today) },
            sentinelBreaker: breaker, runSentinel: { _ = self.sentinel() },
            notify: Notifier.hasBundle ? { self.notify(title: $0, body: $1, id: $2) } : nil))
        if let sent {
            queue.async { [self] in
                scheduler.summarySent(day: sent)
                RuntimeState.update(runtimeDir) { $0.lastSummaryDate = sent }
            }
        }
        return outcome
    }

    func checkAlerts() -> JobOutcome {
        let last = queue.sync { model?.last_success }
        let (outcome, alerts, model) = AlertsJob.run(authorized: Notifier.authorized, model: ModelStatus.read,
                                                     lastModelSuccess: last, now: Date())
        queue.async { [self] in
            self.alerts = alerts
            self.model = model
        }
        return outcome
    }

    @discardableResult
    func notify(title: String, body: String, id: String) -> Bool {
        let ok = Notifier.post(title: title, body: body, id: id)
        if !ok { log("notification_failed id=\(id.prefix(32))") }
        return ok
    }

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
            // Awake time, as the watchdog counts it: a job the Mac slept through is not wedged.
            // A job with no budget (backup) is never wedged by time; its own cutoff stops it when it makes no progress.
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

    var powerPort: IONotificationPortRef?
    var rootPort: io_connect_t = 0
    var notifier: io_object_t = 0

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
