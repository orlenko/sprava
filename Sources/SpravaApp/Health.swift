import AppKit
import Combine
import ServiceManagement
import SpravaCore
import SwiftUI

/// The Health page's model (architecture 3.1, 3.3, 3.6). It reads the heartbeat file, so it can tell a dead
/// runtime from a quiet one without talking to it.
@MainActor
final class HealthModel: ObservableObject {
    static let runtimePlist = "ca.orlenko.sprava.runtime.plist"
    static let watchPlist = "ca.orlenko.sprava.watch.plist"
    static let runtimeLabel = "ca.orlenko.sprava.runtime"

    @Published var heartbeat: Result<Heartbeat, Heartbeat.ReadError> = .failure(.missing)
    @Published var runtimeStatus: SMAppService.Status = .notRegistered
    @Published var watchStatus: SMAppService.Status = .notRegistered
    @Published var watchRecord: String?
    @Published var refusals: [String] = []
    @Published var message: String?
    @Published var now = Date()
    @Published var findings: [Doctor.Finding] = []
    @Published var backups: [(String, Bool)] = []
    var lastDoctor: Date?
    var lastWake: Date?

    let runtimeDir = SpravaPaths.supportDirectory().appendingPathComponent("runtime", isDirectory: true)
    private var observers: [Any] = []

    init() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lastWake = Date() }
            })
    }

    var runtime: SMAppService { .agent(plistName: Self.runtimePlist) }
    var watcher: SMAppService { .agent(plistName: Self.watchPlist) }

    var backgroundOffByChoice: Bool {
        FileManager.default.fileExists(atPath: runtimeDir.appendingPathComponent("background-off").path)
    }

    func refresh() {
        now = Date()
        heartbeat = Heartbeat.read(runtimeDir.appendingPathComponent(Heartbeat.fileName))
        runtimeStatus = runtime.status
        watchStatus = watcher.status
        watchRecord = (try? String(contentsOf: runtimeDir.appendingPathComponent("watch.json"), encoding: .utf8))
        let log = (try? String(contentsOf: runtimeDir.appendingPathComponent("lease-refusals.log"), encoding: .utf8)) ?? ""
        refusals = Array(log.split(separator: "\n").suffix(3).map(String.init))
        // The doctor reads only; it runs here at most once a minute, so it works while the runtime is stopped.
        if lastDoctor.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            lastDoctor = now
            let support = SpravaPaths.supportDirectory()
            let url = LifeprojRegistry.defaultPath()
            let registry = FileManager.default.fileExists(atPath: url.path) ? try? LifeprojRegistry.load(from: url) : nil
            let rows = Shelf.rows(registry: registry, picked: ShelfStore(supportDirectory: support).pickedFolders())
            findings = Doctor.run(rows: rows, deviceID: DeviceID.load(support: support), registry: registry, support: support)
            // Backup is observed, never driven (mvp.md feature 8): cmirror's registry says which binders it mirrors.
            backups = rows.filter(\.teka.isAdopted).map { ($0.name, $0.source == .registry) }
        }
    }

    /// The beat's grade; red when there is no valid heartbeat.
    var beatGrade: HealthGrade {
        guard case .success(let beat) = heartbeat, let beatAt = ISOTime.date(beat.beat_at) else {
            return runtimeStatus == .enabled ? .red : .unknown
        }
        let alive = ProcessCheck.isAlive(pid: beat.pid, startedAt: ISOTime.date(beat.started_at))
        let wake = [lastWake, ISOTime.date(beat.last_wake_at)].compactMap { $0 }.max()
        return HealthGrade.beat(beatAt, lastWake: wake, now: now, pidAlive: alive)
    }

    /// Where the app runs from. Registering from a disk image or a translocated copy would point launchd at a
    /// path that disappears (architecture 3.1).
    var locationProblem: String? {
        let path = Bundle.main.bundlePath
        if Bundle.main.bundleURL.pathExtension != "app" { return "Sprava is not running from an app bundle." }
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "Move Sprava to Applications first."
        }
        return nil
    }

    func turnOn() {
        if let problem = locationProblem {
            message = problem
            return
        }
        do {
            try? FileManager.default.removeItem(at: runtimeDir.appendingPathComponent("background-off"))
            try runtime.register()
            try watcher.register()
            message = nil
        } catch {
            message = "Could not turn on background work: \(error.localizedDescription)"
        }
        refresh()
        if runtime.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func turnOff() {
        do {
            try AtomicFile.makePrivateFolder(runtimeDir)
            try Data().write(to: runtimeDir.appendingPathComponent("background-off"))
            try runtime.unregister()
            try watcher.unregister()
        } catch {
            message = "Could not turn off background work: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Restart a stuck runtime. `launchctl kickstart -k` restarts the job in place; how `register()` behaves on
    /// an enabled but stuck job is spike b (architecture 3.3), so kickstart is tried first.
    func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(getuid())/\(Self.runtimeLabel)"]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                try runtime.unregister()
                try runtime.register()
            }
            message = "Restart requested."
        } catch {
            message = "Restart failed: \(error.localizedDescription)"
        }
        refresh()
    }
}

extension HealthGrade {
    var color: Color {
        switch self {
        case .green: .green
        case .waking: .blue
        case .amber: .orange
        case .red: .red
        case .unknown: .gray
        }
    }
}

struct HealthView: View {
    @ObservedObject var model: HealthModel

    var body: some View {
        List {
            Section("Runtime") { runtimeLines }
            if case .success(let beat) = model.heartbeat {
                Section("Jobs") {
                    ForEach(beat.jobs.keys.sorted(), id: \.self) { key in
                        JobLine(key: key, job: beat.jobs[key]!, beat: beat, lastWake: model.lastWake, now: model.now)
                    }
                }
                Section("The clerk") { clerkLine(beat) }
                Section("Alerts") { alertsLine(beat) }
            }
            Section("Backup") {
                if model.backups.isEmpty { Text("No adopted binders yet.").foregroundStyle(.secondary) }
                ForEach(Array(model.backups.enumerated()), id: \.offset) { _, b in
                    HStack {
                        Circle().fill(b.1 ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(b.0)
                        Spacer()
                        Text(b.1 ? "mirrored by cmirror · last backup: unknown" : "no backup: register it with cmirror by hand")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Doctor") {
                if model.findings.isEmpty { Text("No findings.").foregroundStyle(.secondary) }
                ForEach(Array(model.findings.enumerated()), id: \.offset) { _, f in
                    HStack(alignment: .top) {
                        Text(f.level == .fix ? "Fix" : "Note").font(.caption.bold())
                            .foregroundStyle(f.level == .fix ? .orange : .secondary).frame(width: 34, alignment: .leading)
                        Text([f.binder, f.text].compactMap { $0 }.joined(separator: ": "))
                    }
                }
            }
            if let watch = model.watchRecord {
                Section("Outside watcher") { Text(watch).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    @ViewBuilder var runtimeLines: some View {
        let grade = model.beatGrade
        HStack {
            Circle().fill(grade.color).frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(statusText(grade)).font(.headline)
                if case .success(let beat) = model.heartbeat {
                    Text("pid \(beat.pid) · build \(beat.build) · restarts today \(beat.restarts_today ?? 0)"
                        + (beat.lease.duplicates_refused_today > 0
                            ? " · duplicate starts refused \(beat.lease.duplicates_refused_today)" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            buttons(grade)
        }
        if let message = model.message { Text(message).foregroundStyle(.orange) }
        if let problem = model.locationProblem { Text(problem).foregroundStyle(.orange) }
        ForEach(model.refusals, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
    }

    func statusText(_ grade: HealthGrade) -> String {
        switch model.runtimeStatus {
        case .notRegistered, .notFound:
            if case .success = model.heartbeat, grade == .green {
                return "A runtime is running that launchd did not start (a development run)"
            }
            return model.backgroundOffByChoice ? "Background work is off (your choice)" : "Background work is not set up"
        case .requiresApproval:
            return "Waiting for your approval in System Settings › General › Login Items"
        case .enabled:
            break
        @unknown default:
            break
        }
        guard case .success(let beat) = model.heartbeat, let beatAt = ISOTime.date(beat.beat_at) else {
            if case .failure(.invalid) = model.heartbeat { return "Health data unreadable" }
            return "Runtime has not started yet"
        }
        let age = Int(model.now.timeIntervalSince(beatAt))
        switch grade {
        case .green: return "Runtime running · last heartbeat \(age) s ago"
        case .waking: return "Waking up"
        case .amber: return "The runtime may be stuck · last heartbeat \(age / 60) min ago"
        case .red:
            if !ProcessCheck.isAlive(pid: beat.pid, startedAt: ISOTime.date(beat.started_at)) {
                return "Runtime stopped · last seen \(age / 60) min ago"
            }
            return "Runtime not answering (pid \(beat.pid)) · last heartbeat \(age / 60) min ago"
        case .unknown: return "Unknown"
        }
    }

    @ViewBuilder func buttons(_ grade: HealthGrade) -> some View {
        switch model.runtimeStatus {
        case .enabled:
            if grade == .red || grade == .amber { Button("Restart") { model.restart() } }
            Button("Turn Off") { model.turnOff() }
        case .requiresApproval:
            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
        default:
            Button(model.backgroundOffByChoice ? "Turn On" : "Set Up Background Work") { model.turnOn() }
        }
    }

    @ViewBuilder func clerkLine(_ beat: Heartbeat) -> some View {
        if let m = beat.model {
            let words: [String: String] = [
                "available": "Apple Intelligence model available",
                "deviceNotEligible": "This Mac cannot run Apple Intelligence",
                "appleIntelligenceNotEnabled": "Apple Intelligence is off in System Settings",
                "modelNotReady": "The model is still downloading",
            ]
            Text((words[m.availability] ?? m.availability) + (m.context_size.map { " · context \($0) tokens" } ?? ""))
        } else {
            Text("Not checked yet").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder func alertsLine(_ beat: Heartbeat) -> some View {
        if let alerts = beat.alerts, alerts.authorized {
            Text("Notifications allowed")
        } else {
            Text("Alerts are off: Sprava cannot warn you when it stops").foregroundStyle(.red)
        }
    }
}

struct JobLine: View {
    let key: String
    let job: Heartbeat.Job
    let beat: Heartbeat
    let lastWake: Date?
    let now: Date

    var body: some View {
        let started = ISOTime.date(beat.started_at) ?? now
        let wake = [lastWake, ISOTime.date(beat.last_wake_at)].compactMap { $0 }.max()
        let grade = HealthGrade.job(job, startedAt: started, lastWake: wake, now: now)
        HStack {
            Circle().fill(grade.color).frame(width: 8, height: 8)
            Text(key).font(.body.monospaced()).frame(width: 120, alignment: .leading)
            Text(detail).foregroundStyle(.secondary)
            Spacer()
            if let median = job.median_ms {
                Text("median \(median) ms · slowest \(job.slowest_of_twenty_ms ?? median) ms")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var detail: String {
        var parts: [String] = [job.last_outcome]
        if let success = ISOTime.date(job.last_success) {
            parts.append("last success \(success.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("no success yet")
        }
        if job.breaker != "closed" { parts.append("breaker \(job.breaker.replacingOccurrences(of: "_", with: "-"))") }
        if job.wedged { parts.append("wedged") }
        if let error = job.last_error, job.consecutive_failures > 0 {
            parts.append("\(error.code)" + (error.culprit.map { ": \($0)" } ?? ""))
        }
        return parts.joined(separator: " · ")
    }
}
