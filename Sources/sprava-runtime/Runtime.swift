import Darwin
import Foundation
import FoundationModels
import IOKit.pwr_mgt
import Backup
import BinderFormat
import BinderStore
import Brains
import Capture
import Clerk
import Extract
import Hub
import Services
import Shelf
import SpravaKit
import UserNotifications

/// The supervised runtime (architecture section 3): one process, one lease, a heartbeat every 30 seconds, a
/// watchdog, and timed jobs with breakers. In MVP increment 2 its jobs only read binders; it writes nothing
/// inside any binder. This file is the process: its state, startup, heartbeat, watchdog, sleep and exits; job
/// scheduling is in `RuntimeScheduling.swift` and each job's body in `RuntimeJobs.swift`.
final class Runtime: @unchecked Sendable {
    static let build = "0.1.0 (2)"
    static let xpcProtocol = 1

    let support: URL
    let runtimeDir: URL
    let queue = DispatchQueue(label: "sprava.runtime.state")
    let startedAt = Date()
    let lease: Lease
    var records: JobRecords
    var lastWake: Date?
    var tick: UInt64 = 0
    var alerts: Heartbeat.Alerts?
    var model: Heartbeat.Model?
    var refusalsToday = 0
    var restartsToday = 0
    var lastSentinelDate: String?
    var lastSummaryDate: String?
    var deadlines = JobDeadlines()
    var nextSummary: Date
    /// Failed summary runs on one day (`SummaryRetry`): the day, and how many.
    var summaryFailures: (day: String, count: Int) = ("", 0)
    var timeouts: [String: Date] = [:]   // job key -> when it overran
    var runGeneration: [String: Int] = [:]
    var timers: [DispatchSourceTimer] = []
    var xpc: XPCService?
    /// The jobs' budgets and the app requests' (`RequestQueues`), so the watchdog names a request that hangs too.
    let watch = WatchBox(budgets: Runtime.specs.mapValues(\.budget).merging(RequestQueues.budgets) { job, _ in job })
    /// Cards Sprava wrote whose digests could not be recorded yet.
    let trustBacklog: TrustBacklog
    var commands: Commands?
    /// Set when this Mac's device id cannot be read: nothing is written until it is repaired.
    var deviceIDError: String?
    /// Jobs run concurrently; the opaque binder id file is read, changed and written by one at a time.
    let idsLock = NSLock()
    var mcp: MCPListener?

    static let specs: [String: JobSpec] = [
        "heartbeat": JobSpec(key: "heartbeat", budget: .seconds(1), expectedCadence: 30, breakerThreshold: 3),
        "sentinel": JobSpec(key: "sentinel", budget: .seconds(60), expectedCadence: 3600, breakerThreshold: 3),
        "summary": JobSpec(key: "summary", budget: .seconds(5), expectedCadence: 86_400, breakerThreshold: 2),
        "alerts": JobSpec(key: "alerts", budget: .seconds(5), expectedCadence: 3600, breakerThreshold: 3),
        "hub": JobSpec(key: "hub", budget: .seconds(30), expectedCadence: 300, breakerThreshold: 3),
        "capture": JobSpec(key: "capture", budget: .seconds(10), expectedCadence: 15, breakerThreshold: 3),
        "intake": JobSpec(key: "intake", budget: .seconds(600), expectedCadence: 30, breakerThreshold: 3),
        "clerk": JobSpec(key: "clerk", budget: .seconds(300), expectedCadence: nil, breakerThreshold: 3),
        "dashboard": JobSpec(key: "dashboard", budget: .seconds(30), expectedCadence: 60, breakerThreshold: 3),
        // A first backup of a large binder takes long; the job is never killed for that (docs/backup.md §3.3).
        "backup": JobSpec(key: "backup", budget: .seconds(3 * 3600), expectedCadence: nil, breakerThreshold: 3),
    ]

    init(support: URL, lease: Lease) {
        self.support = support
        runtimeDir = support.appendingPathComponent("runtime", isDirectory: true)
        self.lease = lease
        trustBacklog = TrustBacklog.shared(support: support)
        let (loaded, setAside) = JobRecords.loadAtStart(runtimeDir.appendingPathComponent("breakers.json"), jobs: Array(Self.specs.keys))
        records = loaded
        let (state, stateSetAside) = RuntimeState.loadAtStart(runtimeDir)
        refusalsToday = state.refusalsToday
        restartsToday = state.startsToday
        lastSummaryDate = state.lastSummaryDate
        lastSentinelDate = state.lastSentinelDate
        // A summary missed while the Mac was asleep or the runtime down is sent on the next start that day,
        // and only once today's summary time has passed.
        nextSummary = nextSummaryTime(now: Date(), lastSent: state.lastSummaryDate)
        if let setAside { log("breakers_unreadable kept_as=\(setAside.lastPathComponent) breakers=half_open") }
        if let stateSetAside { log("runtime_state_unreadable kept_as=\(stateSetAside.lastPathComponent) summary_today=counted_as_sent") }
    }

    func log(_ line: String) {
        AtomicFile.appendLine("\(ISOTime.string(Date())) \(line)", to: runtimeDir.appendingPathComponent("jobs.log"))
    }

    /// Set while `runtime/breakers.json` cannot be saved, so the failure is logged once.
    var breakersUnwritable = false
    /// File events on the capture root and each device folder start a sweep at once; the 15-second sweep is the
    /// guarantee when an event is missed.
    var captureSources: [String: DispatchSourceFileSystemObject] = [:]
    var captureAgain = false

    // MARK: - Start

    func start() {
        log("start pid=\(getpid()) build=\(Self.build)")
        RuntimeState.recordStart(runtimeDir)
        installSignalHandlers()
        startHeartbeat()
        startWatchdog()
        startPowerNotifications()
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.clockChanged(reason: "clock") }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.clockChanged(reason: "time_zone") }
        }
        // The device id is read once. One that cannot be read is never replaced: every binder this Mac owns names
        // it. Without it there are no commands, so nothing is written, and the jobs that write report the error.
        let deviceID: String
        do {
            deviceID = try DeviceID.load(support: support)
        } catch {
            deviceIDError = "\(error)"
            log("device_id_unreadable writes=off")
            startScheduler()
            return
        }
        let commands = Commands(support: support, deviceID: deviceID)
        self.commands = commands
        // A failure here is the capture job's to report: its sweep reads the same record.
        do { try commands.inbox.registerProducer(folder: commands.deviceID, app: "sprava") } catch { log("capture producer_unregistered") }
        // No backup request runs yet, so one left "running" was cut off; peeked documents go after a day.
        do { try BackupRequests(support: support).recoverInterrupted() } catch { log("backup requests_unreadable") }
        Backup(support: support, key: nil).cleanPeeks()
        let service = XPCService(commands: commands, watch: watch) { [weak self] line in self?.log(line) }
        service.start()
        xpc = service
        let support = self.support
        let listener = MCPListener(support: support, commands: commands, queue: service.queue, shelf: {
            return ShelfStore(supportDirectory: support).rows()
        }, log: { [weak self] line in self?.log(line) })
        do {
            try listener.start()
            mcp = listener
        } catch {
            log("mcp_listener error=\(error)")
        }
        startScheduler()
    }

    // MARK: - Heartbeat and watchdog (architecture 3.3)

    func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 30)
        timer.setEventHandler { [weak self] in self?.beat() }
        timer.resume()
        timers.append(timer)
    }

    func beat() {
        let now = Date()
        tick &+= 1
        watch.beat(tick)
        records.jobs["heartbeat", default: JobRecord()].start(at: now)
        let started = DispatchTime.now()
        var outcome = JobOutcome.ok
        do {
            try AtomicFile.write(try heartbeat(now: now).encoded(), to: runtimeDir.appendingPathComponent(Heartbeat.fileName))
        } catch {
            outcome = .error(code: "write_failed", culprit: "\(error)")
        }
        finish("heartbeat", outcome, started: started)
    }

    func heartbeat(now: Date) -> Heartbeat {
        var jobs: [String: Heartbeat.Job] = [:]
        for (key, spec) in Self.specs {
            var record = records.jobs[key] ?? JobRecord()
            if key == "heartbeat" { record.running = false }   // this beat is the one being written
            // Awake time, as the watchdog counts it: a job the Mac slept through is not wedged.
            var wedged = false
            if record.running, let running = watch.runningFor(key) {
                wedged = running > max(spec.budget, .seconds(1)) * 2
            }
            jobs[key] = record.heartbeatJob(spec: spec, now: now, wedged: wedged)
        }
        return Heartbeat(
            pid: getpid(), started_at: ISOTime.string(startedAt), beat_at: ISOTime.string(now),
            last_wake_at: lastWake.map { ISOTime.string($0) }, build: Self.build, xpc_protocol: Self.xpcProtocol,
            lease: .init(inode: lease.inode, duplicates_refused_today: refusalsToday),
            restarts_today: max(0, restartsToday - 1), alerts: alerts, runtime_key: nil,
            stage_crashes: [:], model: model, outbound_today: [:], jobs: jobs)
    }

    /// A separate thread checks the tick on a clock that stops while the Mac sleeps. No tick for 120 seconds of
    /// awake time, or a job wedged for 10 minutes, ends the process with status 70 so launchd starts a fresh one.
    func startWatchdog() {
        let thread = Thread { [weak self] in
            let clock = SuspendingClock()
            var lastTick: UInt64 = 0
            var lastChange = clock.now
            while let self {
                Thread.sleep(forTimeInterval: 60)
                // Read through the lock-protected box, never the state queue, which may be what hung.
                let (tick, wedged) = self.watch.read()
                if tick != lastTick {
                    lastTick = tick
                    lastChange = clock.now
                }
                if lastChange.duration(to: clock.now) > .seconds(120) {
                    self.log("watchdog stalled exit=70")
                    exit(70)
                }
                if let culprit = wedged {
                    JobRecords.recordWatchdogExit(job: culprit, url: self.runtimeDir.appendingPathComponent("breakers.json"))
                    self.log("watchdog wedged job=\(culprit) exit=70")
                    exit(70)
                }
            }
        }
        thread.name = "sprava.watchdog"
        thread.start()
    }

    // MARK: - Sleep and wake (architecture 3.3; spike i)

    var powerPort: IONotificationPortRef?
    var rootPort: io_connect_t = 0
    var notifier: io_object_t = 0

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
        if let powerPort {
            IONotificationPortSetDispatchQueue(powerPort, queue)
        } else {
            log("power_notifications unavailable")
        }
    }

    func woke() {
        lastWake = Date()
        log("wake")
        beat()
        deadlines.sentinel = Date()
        if nextSummary < Date() { nextSummary = Date() }
    }

    // MARK: - Exits

    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in
                if let self {
                    self.log("exit reason=signal_\(sig)")
                    try? self.records.save(self.runtimeDir.appendingPathComponent("breakers.json"))
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    var signalSources: [DispatchSourceSignal] = []
}
