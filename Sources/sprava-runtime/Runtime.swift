import Backup
import BinderStore
import Brains
import Clerk
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
    /// Development never selects the production credential backend or registers Phone actions.
    let development: Bool
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
    /// The MCP listener on `mcp/mcp.sock`, which brains reach through the sprava-mcp shim (architecture 7.2).
    var mcp: MCPListener?
    var commands: Commands?
    /// Set when this Mac's device id cannot be read: nothing is written until it is repaired.
    var deviceIDError: String?
    /// The jobs' budgets and the app requests' (`RequestQueues`), so the watchdog names a request that hangs too.
    let watch = WatchBox(budgets: Scheduler.specs.mapValues(\.budget).merging(RequestQueues.budgets) { job, _ in job })
    /// Jobs run concurrently; the opaque binder id file is read, changed and written by one at a time.
    let idsLock = NSLock()
    /// Cards Sprava wrote whose digests could not be recorded yet.
    let trustBacklog: TrustBacklog
    /// File events on the capture root start a sweep at once; one that comes during a sweep runs it again.
    var captureSources: [String: DispatchSourceFileSystemObject] = [:]
    var captureAgain = false
    /// IOKit power notifications (`Runtime+Health.swift`).
    var powerPort: IONotificationPortRef?
    var rootPort: io_connect_t = 0
    var notifier: io_object_t = 0

    var breakersURL: URL { runtimeDir.appendingPathComponent("breakers.json") }

    init(support: URL, lease: Lease, development: Bool) {
        self.support = support
        self.development = development
        runtimeDir = support.appendingPathComponent("runtime", isDirectory: true)
        self.lease = lease
        trustBacklog = TrustBacklog(support: support)
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
            // No backup request runs yet, so one left "running" was cut off by the stop.
            do { try BackupRequests(support: support).recoverInterrupted() } catch { log("backup requests_unreadable") }
            let companion: CompanionRuntimeRequests?
            if development { companion = nil }
            else { companion = try .production(support: support, watch: watch) }
            let service = XPCService(commands: commands, watch: watch, companion: companion) { [weak self] line in self?.log(line) }
            service.start()
            xpc = service
            // Brains share the command queue with the app: one writer.
            let support = support
            let listener = MCPListener(support: support, commands: commands, queue: service.queue, shelf: {
                ShelfStore(supportDirectory: support).rows()
            }, log: { [weak self] line in self?.log(line) })
            do {
                try listener.start()
                mcp = listener
            } catch {
                log("mcp_listener error=\(error)")
            }
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

    /// Every job the scheduler starts.
    func body(for key: String) -> (@Sendable () -> JobOutcome)? {
        switch key {
        case "sentinel": { [unowned self] in sentinel() }
        case "summary": { [unowned self] in summary() }
        case "alerts": { [unowned self] in checkAlerts() }
        case "capture": { [unowned self] in capture() }
        case "intake": { [unowned self] in IntakeJob.run(jobContext()) }
        case "clerk": { [unowned self] in clerk() }
        case "dashboard": { [unowned self] in DashboardJob.run(jobContext()) { notify(title: $0, body: $1, id: $2) } }
        case "hub": { [unowned self] in HubJob.run(jobContext()) }
        case "backup": { [unowned self] in
            BackupJob.run(jobContext(), backup: Backup(support: support)) { notify(title: $0, body: $1, id: $2) }
        }
        default: nil
        }
    }

    /// What the area jobs need from the runtime, read on the state queue.
    func jobContext() -> JobContext {
        let support = support
        let (commands, deviceIDError) = queue.sync { (self.commands, self.deviceIDError) }
        return JobContext(support: support, commands: commands, deviceIDError: deviceIDError,
                          rows: { try ShelfStore(supportDirectory: support).rowsForJobs() }, commandQueue: xpc?.queue,
                          log: { [weak self] in self?.log($0) }, idsLock: idsLock, trustBacklog: trustBacklog)
    }

    func capture() -> JobOutcome {
        let context = jobContext()
        let outcome = CaptureJob.run(context)
        if let root = context.commands?.inbox.root { queue.async { [self] in watchCaptureFolders(root) } }
        return outcome
    }

    func clerk() -> JobOutcome {
        let (outcome, read) = ClerkJob.run(jobContext(), model: AppleClerkModel.load().map { $0 as any ClerkModel }.mapError { $0 as Error })
        if read > 0 { queue.async { [self] in model?.last_success = ISOTime.string(Date()) } }
        return outcome
    }

    /// File events on the capture root and each device folder start a sweep at once; the 15-second sweep is the
    /// guarantee when an event is missed.
    func watchCaptureFolders(_ root: URL) {
        var folders = [root]
        folders += ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { SafeFile.isTrustedFolder($0) }
        for folder in folders where captureSources[folder.path] == nil {
            let fd = open(folder.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    source.cancel()
                    captureSources[folder.path] = nil
                }
                run("capture") { [unowned self] in capture() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            captureSources[folder.path] = source
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
        if record.running, key == "capture" { captureAgain = true }   // an event during a sweep: sweep once more
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
        defer {
            if key == "capture", captureAgain {
                captureAgain = false
                run("capture") { [unowned self] in capture() }
            }
        }
        let ms = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        let final = timeouts.removeValue(forKey: key) != nil ? JobOutcome.timeout : outcome
        let before = records.jobs[key]?.breaker
        records.jobs[key, default: JobRecord()].finish(final, at: Date(), durationMS: ms,
                                                       threshold: Scheduler.specs[key]?.breakerThreshold ?? 3)
        if !["heartbeat", "capture", "intake", "clerk", "dashboard"].contains(key) || final != .ok {
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
}
