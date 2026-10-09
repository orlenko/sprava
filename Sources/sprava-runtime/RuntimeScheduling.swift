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

/// Job scheduling (architecture 3.4): when each job runs, its budget, and how its outcome is recorded.
extension Runtime {
    func startScheduler() {
        let scheduler = DispatchSource.makeTimerSource(queue: queue)
        scheduler.schedule(deadline: .now() + 1, repeating: 15)
        scheduler.setEventHandler { [weak self] in self?.schedule() }
        scheduler.resume()
        timers.append(scheduler)
    }

    func clockChanged(reason: String) {
        log("clock_changed reason=\(reason)")
        let now = Date()
        // Every wall-clock deadline: after a jump back, none of them waits out the jump.
        deadlines.clockChanged(now: now)
        nextSummary = nextSummaryTime(now: now, lastSent: lastSummaryDate)
    }

    func schedule() {
        let now = Date()
        if now >= deadlines.sentinel { run("sentinel") { self.sentinel() } }
        if now >= deadlines.alerts { run("alerts") { self.checkAlerts() } }
        if now >= nextSummary { run("summary") { self.summary() } }
        if now >= deadlines.hub { run("hub") { self.hub() } }
        run("capture") { self.capture() }   // every 15 s; file events call it sooner
        run("clerk") { self.clerk() }
        if now >= deadlines.dashboard { run("dashboard") { self.dashboards() } }
        run("backup") { self.backup() }
        if now >= deadlines.intake { run("intake") { self.intake() } }
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
        watch.started(key)
        runGeneration[key, default: 0] += 1
        let generation = runGeneration[key]!
        switch key {
        case "sentinel": deadlines.sentinel = Date().addingTimeInterval(3600)
        case "alerts": deadlines.alerts = Date().addingTimeInterval(3600)
        case "summary": nextSummary = nextClockTime(hour: 8, minute: 0, after: Date())
        case "hub": deadlines.hub = Date().addingTimeInterval(300)
        case "intake": deadlines.intake = Date().addingTimeInterval(30)
        case "dashboard": deadlines.dashboard = Date().addingTimeInterval(60)
        default: break
        }
        let started = DispatchTime.now()
        let budget = Double(spec.budget.components.seconds)
        queue.asyncAfter(deadline: .now() + budget) { [weak self] in
            // Only this run's timer counts: a timer left from an earlier run never marks a later one.
            guard let self, self.runGeneration[key] == generation, self.records.jobs[key]?.running == true, self.timeouts[key] == nil else { return }
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
        if key == "summary" {
            // Starting moved the next run to tomorrow; a failed run is tried again today (`SummaryRetry`).
            let now = Date()
            let day = CalendarDate.today(now: now).description
            if summaryFailures.day != day { summaryFailures = (day, 0) }
            if final != .ok, final != .skipped, final != .idle { summaryFailures.count += 1 }
            nextSummary = SummaryRetry.next(after: final, now: now, failedToday: summaryFailures.count)
            if nextSummary < nextClockTime(hour: 8, minute: 0, after: now) { log("summary retry_in_s=\(Int(SummaryRetry.delay))") }
        }
        if !["heartbeat", "capture", "intake", "clerk", "dashboard", "backup"].contains(key) || final != .ok {
            var line = "job=\(key) outcome=\(records.jobs[key]?.lastOutcome ?? "?") ms=\(ms)"
            if case .error(let code, _) = final { line += " code=\(code)" }
            log(line)
        }
        if before != "open", after == "open" {
            log("breaker_open job=\(key)")
            notify(title: "Sprava", body: "A background job keeps failing. Open Sprava's Health page.",
                   id: "breaker-\(key)")
        }
        // Kept in memory either way; a save that fails is logged once and tried again after the next job.
        do {
            try records.save(runtimeDir.appendingPathComponent("breakers.json"))
            breakersUnwritable = false
        } catch {
            if !breakersUnwritable { log("breakers_unwritable") }
            breakersUnwritable = true
        }
    }

    /// Watches the capture root and each device folder for file events (`captureSources`).
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
}
