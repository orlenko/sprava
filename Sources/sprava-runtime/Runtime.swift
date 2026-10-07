import Darwin
import Foundation
import FoundationModels
import IOKit.pwr_mgt
import SpravaCore
import UserNotifications

/// The supervised runtime (architecture section 3): one process, one lease, a heartbeat every 30 seconds, a
/// watchdog, and timed jobs with breakers. In MVP increment 2 its jobs only read binders; it writes nothing
/// inside any binder.
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
    var nextSentinel = Date()
    var nextSummary: Date
    var nextAlertsCheck = Date()
    var nextHub = Date()
    var nextIntake = Date()
    var nextImport = Date()
    var timeouts: [String: Date] = [:]   // job key -> when it overran
    var timers: [DispatchSourceTimer] = []
    var xpc: XPCService?
    let watch = WatchBox()
    var commands: Commands?
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
        "intake": JobSpec(key: "intake", budget: .seconds(60), expectedCadence: 30, breakerThreshold: 3),
        "importer": JobSpec(key: "importer", budget: .seconds(30), expectedCadence: 60, breakerThreshold: 3),
        "clerk": JobSpec(key: "clerk", budget: .seconds(120), expectedCadence: nil, breakerThreshold: 3),
    ]

    init(support: URL, lease: Lease) {
        self.support = support
        runtimeDir = support.appendingPathComponent("runtime", isDirectory: true)
        self.lease = lease
        records = JobRecords.load(runtimeDir.appendingPathComponent("breakers.json"))
        let state = RuntimeState.load(runtimeDir)
        refusalsToday = state.refusalsToday
        restartsToday = state.startsToday
        lastSummaryDate = state.lastSummaryDate
        lastSentinelDate = state.lastSentinelDate
        // A summary missed while the Mac was asleep or the runtime down is sent on the next start that day,
        // and only once today's summary time has passed.
        nextSummary = nextSummaryTime(now: Date(), lastSent: state.lastSummaryDate)
    }

    func log(_ line: String) {
        AtomicFile.appendLine("\(ISOTime.string(Date())) \(line)", to: runtimeDir.appendingPathComponent("jobs.log"))
    }

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
        let commands = Commands(support: support, deviceID: DeviceID.load(support: support))
        self.commands = commands
        try? commands.inbox.registerProducer(folder: commands.deviceID, app: "sprava")
        let service = XPCService(commands: commands) { [weak self] line in self?.log(line) }
        service.start()
        xpc = service
        let support = self.support
        let listener = MCPListener(support: support, commands: commands, queue: service.queue, shelf: {
            let url = LifeprojRegistry.defaultPath()
            let registry = FileManager.default.fileExists(atPath: url.path) ? try? LifeprojRegistry.load(from: url) : nil
            return Shelf.rows(registry: registry, picked: ShelfStore(supportDirectory: support).pickedFolders())
        }, log: { [weak self] line in self?.log(line) })
        do {
            try listener.start()
            mcp = listener
        } catch {
            log("mcp_listener error=\(error)")
        }
        let scheduler = DispatchSource.makeTimerSource(queue: queue)
        scheduler.schedule(deadline: .now() + 1, repeating: 15)
        scheduler.setEventHandler { [weak self] in self?.schedule() }
        scheduler.resume()
        timers.append(scheduler)
    }

    func clockChanged(reason: String) {
        log("clock_changed reason=\(reason)")
        let now = Date()
        nextSentinel = now
        nextSummary = nextSummaryTime(now: now, lastSent: lastSummaryDate)
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
            var wedged = false
            if record.running, let start = record.lastStart {
                let budget = Double(spec.budget.components.seconds)
                wedged = now.timeIntervalSince(start) > 2 * max(budget, 1)
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

    /// What the watchdog reads: the tick and when each running job started, behind a lock of their own.
    final class WatchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tick: UInt64 = 0
        private var running: [String: Date] = [:]

        func beat(_ t: UInt64) { lock.lock(); tick = t; lock.unlock() }
        func started(_ key: String, at date: Date) { lock.lock(); running[key] = date; lock.unlock() }
        func finished(_ key: String) { lock.lock(); running[key] = nil; lock.unlock() }

        /// The tick, and a job running longer than twice its budget plus 10 minutes.
        func read(now: Date = Date()) -> (UInt64, String?) {
            lock.lock()
            defer { lock.unlock() }
            for (key, start) in running {
                let budget = max(Double(Runtime.specs[key]?.budget.components.seconds ?? 1), 1)
                if now.timeIntervalSince(start) > 2 * budget + 600 { return (tick, key) }
            }
            return (tick, nil)
        }
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
        nextSentinel = Date()
        if nextSummary < Date() { nextSummary = Date() }
    }

    // MARK: - Jobs (architecture 3.4)

    func schedule() {
        let now = Date()
        if now >= nextSentinel { run("sentinel") { self.sentinel() } }
        if now >= nextAlertsCheck { run("alerts") { self.checkAlerts() } }
        if now >= nextSummary { run("summary") { self.summary() } }
        if now >= nextHub { run("hub") { self.hub() } }
        run("capture") { self.capture() }   // every 15 s; file events call it sooner
        run("clerk") { self.clerk() }
        if now >= nextIntake { run("intake") { self.intake() } }
        if now >= nextImport, developerImporterPath() != nil { run("importer") { self.importHolos() } }
        let today = CalendarDate.today(now: now).description
        if lastSentinelDate != nil, lastSentinelDate != today, records.jobs["sentinel"]?.running != true {
            run("sentinel") { self.sentinel() }   // the date changed: recompute at once
        }
    }

    /// Runs a job off the state queue with its budget. An overrun is recorded as a timeout at once; the job is
    /// shown as wedged if it keeps running (architecture 3.4).
    func run(_ key: String, _ body: @escaping @Sendable () -> JobOutcome) {
        guard let spec = Self.specs[key] else { return }
        var record = records.jobs[key] ?? JobRecord()
        if record.running, key == "capture" { captureAgain = true }   // an event during a sweep: sweep once more
        guard !record.running, record.mayRun(now: Date()) else { return }
        record.start(at: Date())
        records.jobs[key] = record
        watch.started(key, at: Date())
        switch key {
        case "sentinel": nextSentinel = Date().addingTimeInterval(3600)
        case "alerts": nextAlertsCheck = Date().addingTimeInterval(3600)
        case "summary": nextSummary = nextClockTime(hour: 8, minute: 0, after: Date())
        case "hub": nextHub = Date().addingTimeInterval(300)
        case "intake": nextIntake = Date().addingTimeInterval(30)
        case "importer": nextImport = Date().addingTimeInterval(60)
        default: break
        }
        let started = DispatchTime.now()
        let budget = Double(spec.budget.components.seconds)
        queue.asyncAfter(deadline: .now() + budget) { [weak self] in
            guard let self, self.records.jobs[key]?.running == true, self.timeouts[key] == nil else { return }
            self.timeouts[key] = Date()
            self.log("job=\(key) outcome=timeout budget_s=\(Int(budget))")
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
                run("capture") { self.capture() }
            }
        }
        let ms = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        let threshold = Self.specs[key]?.breakerThreshold ?? 3
        let final = timeouts.removeValue(forKey: key) != nil ? JobOutcome.timeout : outcome
        let before = records.jobs[key]?.breaker
        records.jobs[key, default: JobRecord()].finish(final, at: Date(), durationMS: ms, threshold: threshold)
        let after = records.jobs[key]?.breaker
        if !["heartbeat", "capture", "intake", "importer", "clerk"].contains(key) || final != .ok {
            var line = "job=\(key) outcome=\(records.jobs[key]?.lastOutcome ?? "?") ms=\(ms)"
            if case .error(let code, _) = final { line += " code=\(code)" }
            log(line)
        }
        if before != "open", after == "open" {
            log("breaker_open job=\(key)")
            notify(title: "Sprava", body: "A background job keeps failing. Open Sprava's Health page.",
                   id: "breaker-\(key)")
        }
        try? records.save(runtimeDir.appendingPathComponent("breakers.json"))
    }

    /// The deadline sentinel: reads every binder on the shelf and records counts per opaque id. Reads only.
    func sentinel() -> JobOutcome {
        let now = Date()
        let today = CalendarDate.today(now: now)
        let registryURL = LifeprojRegistry.defaultPath()
        let registry = FileManager.default.fileExists(atPath: registryURL.path)
            ? try? LifeprojRegistry.load(from: registryURL) : nil
        let rows = Shelf.rows(registry: registry, picked: ShelfStore(supportDirectory: support).pickedFolders())
        let idsURL = support.appendingPathComponent("binder-ids.json")
        idsLock.lock()
        var ids = BinderIDs.load(idsURL)
        let report = SentinelReport.compute(rows: rows, ids: &ids, today: today, now: now)
        let savedIDs = Result { try ids.save(idsURL) }
        idsLock.unlock()
        do {
            try savedIDs.get()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFile.write(try encoder.encode(report), to: runtimeDir.appendingPathComponent("sentinel.json"))
        } catch {
            return .error(code: "write_failed", culprit: "\(error)")
        }
        queue.async { self.lastSentinelDate = today.description; RuntimeState.update(self.runtimeDir) { $0.lastSentinelDate = today.description } }
        // A binder that cannot be read is a finding, not a failed run.
        return rows.isEmpty ? .skipped : .ok
    }

    /// The hub lane (teka-v0 §8; mvp.md feature 7): for each adopted binder this Mac owns, drain the hub's
    /// completions, then publish the slice when it changed. Counts per opaque binder id only.
    func hub() -> JobOutcome {
        let root = HubLane.spoolRoot()
        guard FileManager.default.fileExists(atPath: root.path) else { return .skipped }
        let registryURL = LifeprojRegistry.defaultPath()
        let registry = FileManager.default.fileExists(atPath: registryURL.path) ? try? LifeprojRegistry.load(from: registryURL) : nil
        let rows = Shelf.rows(registry: registry, picked: ShelfStore(supportDirectory: support).pickedFolders())
        let device = DeviceID.load(support: support)
        let mine = rows.filter { $0.teka.isAdopted && Owner.device(of: $0.folder) == device }
        let idsURL = support.appendingPathComponent("binder-ids.json")
        idsLock.lock()
        var ids = BinderIDs.load(idsURL)
        let bids = mine.map { ids.id(for: $0.folder) }
        try? ids.save(idsURL)
        idsLock.unlock()
        var failures: [String] = []
        for (row, bid) in zip(mine, bids) {
            do {
                let drained = try HubLane.drain(row.folder, root: root)
                if !drained.createdProposals.isEmpty, let commands, let xpc {
                    xpc.queue.sync { commands.trustProposals(drained.createdProposals, in: row.folder) }
                    log("hub binder=\(bid) overwritten_change_card=1")
                }
                let published = try HubLane.publish(row.folder, root: root)
                if drained.applied > 0 || drained.skipped > 0 || drained.waitingForYou > 0 {
                    log("hub binder=\(bid) drained=\(drained.applied) skipped=\(drained.skipped) waiting=\(drained.waitingForYou)")
                }
                if case .published(let n, let overwritten) = published {
                    log("hub binder=\(bid) published items=\(n)" + (overwritten ? " overwritten_by_other=true" : ""))
                }
            } catch {
                failures.append(bid)
                log("hub binder=\(bid) error=\(type(of: error))")
            }
        }
        return failures.isEmpty ? .ok : .error(code: "hub_failed", culprit: "binders " + failures.joined(separator: ","))
    }

    /// The capture watcher (architecture 8; mvp.md feature 4): sweeps the capture root and turns each new capture
    /// into a Tier 0 card within the sweep. Runs on the command queue, the single writer. Counts only in the log.
    func capture() -> JobOutcome {
        guard let commands, let xpc else { return .skipped }
        let inbox = commands.inbox
        try? AtomicFile.makePrivateFolder(inbox.root)
        let rows = shelfRows()
        let result = xpc.queue.sync { inbox.sweep(binders: rows, commands: commands) }
        queue.async { self.watchCaptureFolders(inbox.root) }
        let new = result.ingested + result.quarantined + result.duplicates
        if new > 0 || result.refusedFolders > 0 {
            let slowest = result.latencies.max().map { " slowest_s=\(Int($0))" } ?? ""
            log("capture ingested=\(result.ingested) filed=\(result.filed) unfiled=\(result.unfiled) duplicates=\(result.duplicates) quarantined=\(result.quarantined) pending=\(result.pending) refused_folders=\(result.refusedFolders)" + slowest)
        }
        if result.refusedFolders > 0 { return .error(code: "capture_folder_refused", culprit: "\(result.refusedFolders) folder(s)") }
        return .ok   // a sweep that found nothing new still did its work
    }

    /// The intake watcher (mvp.md feature 4): a card for each file that holds still in a binder's intake/.
    func intake() -> JobOutcome {
        guard let commands, let xpc else { return .skipped }
        let rows = shelfRows()
        let result = xpc.queue.sync { IntakeWatcher(support: support).scan(binders: rows, commands: commands) }
        if result.carded > 0 || result.replaced > 0 {
            log("intake carded=\(result.carded) replaced=\(result.replaced) waiting=\(result.waiting) stale=\(result.stale)")
        }
        return .ok
    }

    /// The hidden developer setting (mvp.md increment 5): `developer.json` in Sprava's folder with
    /// `{"holos_importer": "/absolute/path/to/voiceislocal"}`. A background agent has no shell search path.
    func developerImporterPath() -> String? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("developer.json")),
              let path = (try? JSONParser.parse(data).value)?["holos_importer"]?.stringValue,
              path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// The developer importer, every minute: only the read-only `history list --json`.
    func importHolos() -> JobOutcome {
        guard let path = developerImporterPath(), let commands else { return .skipped }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["history", "list", "--json"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return .error(code: "importer_not_started", culprit: nil) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return .error(code: "importer_failed", culprit: "exit \(task.terminationStatus)") }
        do {
            let inbox = commands.inbox
            let r = try HolosImporter(root: inbox.root, support: support).importHistory(data, inbox: inbox)
            if r.written > 0 || r.unreadable > 0 { log("importer written=\(r.written) unreadable=\(r.unreadable)") }
            if r.written > 0 { queue.async { self.run("capture") { self.capture() } } }
            return r.stoppedForGood ? .skipped : .ok
        } catch {
            return .error(code: "importer_unreadable", culprit: nil)
        }
    }

    /// Tier 1 (architecture 5.3): reads the captures whose code-built cards are still untouched, one at a time,
    /// for at most 45 seconds per run. Model calls never hold the command queue. Gated on the author's model
    /// variant for the MVP (mvp.md question 7); `developer.json` `"clerk_any_model": true` lifts the gate.
    func clerk() -> JobOutcome {
        guard let commands, let xpc else { return .skipped }
        let model: AppleClerkModel
        switch AppleClerkModel.load() {
        case .success(let m): model = m
        case .failure: return .skipped
        }
        let anyModel = (try? JSONParser.parse(Data(contentsOf: support.appendingPathComponent("developer.json"))).value["clerk_any_model"]) == .bool(true)
        guard model.contextSize >= 8192 || anyModel else { return .skipped }
        let inbox = commands.inbox
        let started = Date()
        var read = 0
        while Date().timeIntervalSince(started) < 45 {
            guard let work = xpc.queue.sync(execute: { inbox.nextForClerk() }) else { break }
            let rows = shelfRows()
            let filing = FilingList(support: support).binders(rows: rows, deviceID: commands.deviceID)
            let t0 = Date()
            let interp = blocking { await Clerk(model: model).read(work.event, filing: filing, hint: work.hint) }
            let seconds = Date().timeIntervalSince(t0)
            let outcome = xpc.queue.sync { inbox.commitClerk(work, interp, filing: filing, rows: rows, commands: commands, seconds: seconds) }
            log("clerk outcome=\(interp.outcome) items=\(outcome.items) filed=\(outcome.filed) not_sure=\(outcome.unsure) calls=\(interp.calls) ms=\(Int(seconds * 1000))")
            read += 1
        }
        if read > 0 { queue.async { self.model?.last_success = ISOTime.string(Date()) } }
        return .ok
    }

    func shelfRows() -> [ShelfRow] {
        let url = LifeprojRegistry.defaultPath()
        let registry = FileManager.default.fileExists(atPath: url.path) ? try? LifeprojRegistry.load(from: url) : nil
        return Shelf.rows(registry: registry, picked: ShelfStore(supportDirectory: support).pickedFolders())
    }

    /// File events on the capture root and each device folder start a sweep at once; the 15-second sweep is the
    /// guarantee when an event is missed.
    var captureSources: [String: DispatchSourceFileSystemObject] = [:]
    var captureAgain = false

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
                    self.captureSources[folder.path] = nil
                }
                self.run("capture") { self.capture() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            captureSources[folder.path] = source
        }
    }

    /// The daily summary: one notification with counts only, at most once per calendar day.
    func summary() -> JobOutcome {
        let today = CalendarDate.today().description
        if queue.sync(execute: { lastSummaryDate }) == today { return .skipped }
        let reportURL = runtimeDir.appendingPathComponent("sentinel.json")
        func current() -> SentinelReport? {
            guard let data = try? Data(contentsOf: reportURL),
                  let report = try? JSONDecoder().decode(SentinelReport.self, from: data), report.date == today else { return nil }
            return report
        }
        // The sentinel may not have run yet today (a start just after midnight, or the first run): compute it now.
        if current() == nil { _ = sentinel() }
        guard let report = current() else { return .error(code: "sentinel_stale", culprit: nil) }
        if let text = report.summaryText {
            guard notify(title: "Sprava today", body: text, id: "summary-\(today)") else {
                return .error(code: "notification_failed", culprit: nil)
            }
        }
        queue.async { self.lastSummaryDate = today; RuntimeState.update(self.runtimeDir) { $0.lastSummaryDate = today } }
        return .ok
    }

    func checkAlerts() -> JobOutcome {
        let authorized = Notifier.authorized()
        let model = ModelStatus.read()
        queue.async {
            self.alerts = Heartbeat.Alerts(authorized: authorized ?? false, checked_at: ISOTime.string(Date()))
            self.model = model
        }
        // Outside the app bundle (a development run) there is no notification identity: recorded as skipped,
        // and the heartbeat shows alerts as off.
        return authorized == nil ? .skipped : .ok
    }

    @discardableResult
    func notify(title: String, body: String, id: String) -> Bool {
        let ok = Notifier.post(title: title, body: body, id: id)
        if !ok { log("notification_failed id=\(id.prefix(32))") }
        return ok
    }

    // MARK: - Exits

    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in
                self?.log("exit reason=signal_\(sig)")
                try? self?.records.save(self!.runtimeDir.appendingPathComponent("breakers.json"))
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    var signalSources: [DispatchSourceSignal] = []
}

/// Small persisted counters that are not job state.
struct RuntimeState: Codable {
    var day: String = ""
    var startsToday = 0
    var refusalsToday = 0
    var lastSummaryDate: String?
    var lastSentinelDate: String?

    static func url(_ dir: URL) -> URL { dir.appendingPathComponent("state.json") }

    static func load(_ dir: URL) -> RuntimeState {
        var state = (try? Data(contentsOf: url(dir))).flatMap { try? JSONDecoder().decode(RuntimeState.self, from: $0) }
            ?? RuntimeState()
        let today = CalendarDate.today().description
        if state.day != today {
            state.day = today
            state.startsToday = 0
            state.refusalsToday = 0
        }
        return state
    }

    static func update(_ dir: URL, _ change: (inout RuntimeState) -> Void) {
        var state = load(dir)
        change(&state)
        if let data = try? JSONEncoder().encode(state) { try? AtomicFile.write(data, to: url(dir)) }
    }

    static func recordStart(_ dir: URL) { update(dir) { $0.startsToday += 1 } }
    static func recordRefusal(_ dir: URL) { update(dir) { $0.refusalsToday += 1 } }
}

/// Notifications under the app's identity. A helper inside the bundle has the app's bundle as its main bundle;
/// whether macOS delivers its notifications is spike h (architecture 3.7). Outside a bundle (a `swift build`
/// binary) there is no identity, and posting is skipped and reported.
enum Notifier {
    static var hasBundle: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func authorized() -> Bool? {
        guard hasBundle else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = false
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            result = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + 5) == .success ? result : false
    }

    static func post(title: String, body: String, id: String) -> Bool {
        guard hasBundle else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        UNUserNotificationCenter.current().add(request) { error in
            ok = error == nil
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + 5) == .success && ok
    }
}

/// The clerk's line on the Health page: whether the on-device model is available, and its context size.
enum ModelStatus {
    static func read() -> Heartbeat.Model {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return Heartbeat.Model(availability: "available", context_size: model.contextSize, variant: nil,
                                   last_success: nil, errors_24h: nil)
        case .unavailable(let reason):
            let name: String
            switch reason {
            case .deviceNotEligible: name = "deviceNotEligible"
            case .appleIntelligenceNotEnabled: name = "appleIntelligenceNotEnabled"
            case .modelNotReady: name = "modelNotReady"
            @unknown default: name = "modelNotReady"
            }
            return Heartbeat.Model(availability: name, context_size: nil, variant: nil, last_success: nil, errors_24h: nil)
        }
    }
}

/// Waits for async work from a job's thread. Jobs run on a global queue, never on the state queue.
final class BlockingBox<T>: @unchecked Sendable { var value: T? }

func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = BlockingBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        box.value = await body()
        done.signal()
    }
    done.wait()
    return box.value!
}
