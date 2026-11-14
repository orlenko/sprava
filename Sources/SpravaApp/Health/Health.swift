import AppKit
import Combine
import ServiceManagement
import Services
import SpravaKit
import SwiftUI

/// The Health page's model (architecture 3.1, 3.3, 3.6). It reads Services' health snapshot, heartbeat included, so
/// it can tell a dead runtime from a quiet one without talking to it.
@MainActor
final class HealthModel: ObservableObject {
    @Published var heartbeat: Result<Heartbeat, Heartbeat.ReadError> = .failure(.missing)
    @Published var runtimeStatus: SMAppService.Status = .notRegistered
    @Published var watchStatus: SMAppService.Status = .notRegistered
    @Published var watchRecord: String?
    @Published var refusals: [String] = []
    @Published var now = Date()
    @Published var findings: [Doctor.Finding] = []
    /// Why the doctor could not tell which binders are this Mac's: the device id cannot be read.
    @Published var deviceIDError: String?
    /// Starts recorded today in the runtime's own state file, which rises even when no heartbeat is written.
    @Published var startsToday = 0
    @Published private(set) var connectionPresence: RuntimeClient.Presence?
    @Published var backups: [HealthSnapshot.BackupLine] = []
    @Published var backupConfigured = false
    /// Why the backup settings cannot be read, if they cannot: not the same as backup not set up.
    @Published var backupSettingsError: String?
    /// Why the backup's records cannot be read, if they cannot: not the same as no backup yet (#574).
    @Published var backupStateError: String?
    var lastDoctor: Date?
    var lastWake: Date?
    /// The last time the watcher was registered again, the attempt in flight, and why the last one failed (#523).
    var lastWatcherRepair: Date?
    var watcherRepair: Task<Void, Never>?
    @Published var watcherRepairFailure: String?
    /// Whether Health's Details for support is open; its notice opens it.
    @Published var supportOpen = false
    /// Starts the runtime without asking (decisions.md A19). While it starts, launchd can take several seconds, and
    /// that wait is shown as "starting", not as a failure.
    let keeper: RuntimeKeeper

    var starting: Bool { keeper.state == .starting }

    /// The two reads behind the page. Both run off the main actor: a damaged binder (a FIFO where a file should be)
    /// or a slow disk must not freeze the app, even while the page is closed. Tests stand in slow ones.
    struct Reads: Sendable {
        var runtime: @Sendable (URL) -> HealthSnapshot.Runtime = { HealthSnapshot.runtime(support: $0) }
        var checks: @Sendable (URL) -> HealthSnapshot.Checks = { HealthSnapshot.checks(support: $0) }
        /// Registers the outside watcher again (`WatcherRepair`); what went wrong, or nil.
        var repairWatcher: @Sendable () -> String? = { RuntimeStart.reregisterWatcher() }
    }

    let support: URL
    let reads: Reads
    private let client: RuntimeClient?
    private var observers: [Any] = []
    /// The read in flight, if any: never more than one of each, so a read that hangs holds one thread, not one per tick.
    private var runtimeRead: Task<Void, Never>?
    private var checksRead: Task<Void, Never>?
    private var connectionRead: Task<Void, Never>?
    /// A refresh was asked for while the runtime read was in flight: that read's result is older than the request
    /// (a start may have happened since), so it is dropped and the records are read again.
    private var runtimeReadStale = false

    init(support: URL = SpravaPaths.supportDirectory(), reads: Reads = Reads(), keeper: RuntimeKeeper? = nil,
         client: RuntimeClient? = nil, refreshRegistration: Bool = false) {
        self.support = support
        self.reads = reads
        self.client = client
        self.keeper = keeper ?? RuntimeKeeper(system: RuntimeStart.system(support: support), refreshRegistration: refreshRegistration)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lastWake = Date() }
            })
        // The page follows a start: each change of the keeper's state is shown and the records read again.
        observers.append(self.keeper.$state.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.refresh()
        })
    }

    var runtime: SMAppService { .agent(plistName: RuntimeStart.runtimePlist) }
    var watcher: SMAppService { .agent(plistName: RuntimeStart.watchPlist) }

    /// Everything the page shows comes from Services' health snapshot, read here in the app's process so it works
    /// while the runtime is stopped; the page reads no support file or binder file itself. Returns at once: the reads
    /// run in the background and their results are published on the main actor when they arrive.
    func refresh() {
        now = Date()
        runtimeStatus = runtime.status
        watchStatus = watcher.status
        readRuntime()
        if connectionRead == nil, let client {
            connectionRead = Task {
                connectionPresence = await client.presence()
                connectionRead = nil
            }
        }
        // The doctor and the backup records read every binder on the Shelf: at most once a minute.
        if checksRead == nil, lastDoctor.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            lastDoctor = now
            let support = support, read = reads.checks
            checksRead = Task {
                let checks = await Task.detached { read(support) }.value
                checksRead = nil
                findings = checks.findings
                deviceIDError = checks.deviceIDError
                backupConfigured = checks.backupConfigured
                backupSettingsError = checks.backupSettingsError
                backupStateError = checks.backupStateError
                backups = checks.backups
            }
        }
    }

    private func readRuntime() {
        guard runtimeRead == nil else {
            runtimeReadStale = true
            return
        }
        let support = support, read = reads.runtime
        runtimeRead = Task {
            let records = await Task.detached { read(support) }.value
            runtimeRead = nil
            if runtimeReadStale {
                runtimeReadStale = false
                readRuntime()
                return
            }
            heartbeat = records.heartbeat
            watchRecord = records.watchRecord
            refusals = records.refusals
            startsToday = records.startsToday
            repairWatcherIfDue()
        }
    }

    /// Waits until no read is in flight and every result has been published or dropped.
    func settled() async {
        while let read = runtimeRead ?? checksRead ?? connectionRead ?? watcherRepair { await read.value }
    }

    /// A heartbeat proves the process is alive, not that the app can reach its command listener.
    var connectionProblem: String? {
        guard !starting, let connectionPresence, connectionPresence != .answers else { return nil }
        if beatGrade == .green {
            return "Sprava's background part is running, but the app cannot connect to it. Restart it; if this continues, copy Details for support from Health."
        }
        return nil
    }

    var statusGrade: HealthGrade { connectionProblem == nil ? beatGrade : .red }

    /// The beat's grade; red when there is no valid heartbeat.
    var beatGrade: HealthGrade {
        if starting { return .unknown }
        guard case .success(let beat) = heartbeat, let beatAt = ISOTime.date(beat.beat_at) else {
            return runtimeStatus == .enabled ? .red : .unknown
        }
        let alive = ProcessCheck.isAlive(pid: beat.pid, startedAt: ISOTime.date(beat.started_at))
        let wake = [lastWake, ISOTime.date(beat.last_wake_at)].compactMap { $0 }.max()
        return HealthGrade.beat(beatAt, lastWake: wake, now: now, pidAlive: alive)
    }

    var locationProblem: String? { RuntimeStart.locationProblem }

    /// Why the last start failed, when it did.
    var startFailure: String? {
        if case .failed(let why) = keeper.state { return why }
        return nil
    }

    /// Restart a stopped or stuck runtime, or register one that is not registered: `launchctl kickstart -k` first,
    /// then registering again (architecture 3.3). Off the main actor; the page follows the keeper's state.
    func restart() {
        Task { _ = await keeper.restart() }
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

/// Health in plain words (decisions.md D37): the notice first when something is wrong, then each part with what to do
/// about it beside it. Process ids, builds, codes and timings stay whole under a closed Details for support.
struct HealthView: View {
    @ObservedObject var model: HealthModel
    var openBackup: () -> Void = {}

    static let supportID = "support"
    /// The notice's tuned colours, readable as text on a light page as well as a dark one.
    static let needsYou = NoticeLevel.needsYou.color
    static let broken = NoticeLevel.broken.color

    var body: some View {
        ScrollViewReader { scroller in
            List {
                if model.notice != nil {
                    RuntimeBanner(health: model, inset: false, details: {
                        model.supportOpen = true
                        withAnimation { scroller.scrollTo(Self.supportID, anchor: .top) }
                    })
                    .listRowSeparator(.hidden)
                }
                Section("Sprava's background part") { runtimeLines }
                if case .success(let beat) = model.heartbeat {
                    Section("Background jobs") {
                        ForEach(beat.jobs.keys.sorted(), id: \.self) { key in
                            JobLine(key: key, job: beat.jobs[key]!, beat: beat, lastWake: model.lastWake, now: model.now,
                                    restart: model.runtimeStatus == .enabled && model.beatGrade == .green && !model.starting
                                        ? { model.restart() } : nil)
                        }
                    }
                    Section("Apple Intelligence") { clerkLine(beat) }
                    Section("Notifications") { alertsLine(beat) }
                }
                Section("Backup") {
                    Button("Open Backup Settings", action: openBackup).buttonStyle(.link)
                    if let error = model.backupSettingsError { Text("Backup settings cannot be read: \(error)").foregroundStyle(Self.broken) }
                    else if !model.backupConfigured { Text("Backup is not set up.").foregroundStyle(Self.needsYou) }
                    else if let error = model.backupStateError { Text("Backup records cannot be read: \(error)").foregroundStyle(Self.broken) }
                    else if model.backups.isEmpty { Text("No adopted binders yet.").foregroundStyle(.secondary) }
                    ForEach(HealthLine.rows("backup", model.backups)) { line in
                        let b = line.value
                        HStack {
                            Circle().fill(model.grade(b).color).frame(width: 8, height: 8)
                            Text(b.name)
                            Spacer()
                            Text(b.error ?? (model.backupStateError != nil ? "its record cannot be read" : nil)
                                 ?? b.at.map { "backed up \($0.formatted(.relative(presentation: .named)))" } ?? "not backed up yet")
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Section("Checks") {
                    if let error = model.deviceIDError { Text("This Mac's device id cannot be read: \(error)").foregroundStyle(Self.broken) }
                    else if model.findings.isEmpty { Text("Nothing to fix.").foregroundStyle(.secondary) }
                    ForEach(HealthLine.rows("doctor", model.findings)) { line in
                        let f = line.value
                        HStack(alignment: .top) {
                            Text(f.level == .fix ? "Fix" : "Note").font(.caption.bold())
                                .foregroundStyle(f.level == .fix ? Self.needsYou : .secondary).frame(width: 34, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.sentence)
                                Text(f.next).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    DisclosureGroup("Details for support", isExpanded: $model.supportOpen) { support }
                        .id(Self.supportID)
                }
            }
        }
        // The Shelf re-reads health every ten seconds whichever page is open; opening the page reads it at once.
        .onAppear { model.refresh() }
    }

    var supportText: String {
        SupportDetails.text(heartbeat: model.heartbeat, registration: SupportDetails.registration(model.runtimeStatus),
                            startsToday: model.startsToday, refusals: model.refusals, watchRecord: model.watchRecord,
                            problems: model.supportProblems)
    }

    @ViewBuilder var support: some View {
        let text = supportText
        VStack(alignment: .leading, spacing: 8) {
            Text("For someone helping you with a problem.")
                .font(.caption).foregroundStyle(.secondary)
            Text(verbatim: text).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder var runtimeLines: some View {
        let grade = model.beatGrade
        HStack {
            Circle().fill(model.statusGrade.color).frame(width: 10, height: 10)
            Text(statusText(grade)).font(.headline)
            Spacer()
            buttons(grade)
        }
        if let stale = model.staleRuntimeBuild { Text(stale).foregroundStyle(Self.needsYou) }
        if let failure = model.watcherRepairFailure { Text(failure).foregroundStyle(Self.needsYou) }
        if let failure = model.startFailure, failure != model.locationProblem, model.notice?.title != failure {
            Text(failure).foregroundStyle(Self.needsYou)
        }
        if let problem = model.locationProblem, model.notice?.title != problem { Text(problem).foregroundStyle(Self.needsYou) }
    }

    func statusText(_ grade: HealthGrade) -> String {
        if let problem = model.connectionProblem { return problem }
        switch model.runtimeStatus {
        case .notRegistered, .notFound:
            if case .success = model.heartbeat, grade == .green {
                return "Running, started by hand rather than by macOS (a development run)"
            }
            return model.starting ? "Starting…" : "Not running"
        case .requiresApproval:
            return "Waiting for your approval in System Settings › General › Login Items"
        case .enabled:
            break
        @unknown default:
            break
        }
        if model.starting { return "Starting… (this can take up to a minute)" }
        guard case .success(let beat) = model.heartbeat, let beatAt = ISOTime.date(beat.beat_at) else {
            if case .failure(.invalid) = model.heartbeat { return "Its status cannot be read" }
            return "Not started yet"
        }
        let age = Int(model.now.timeIntervalSince(beatAt))
        switch grade {
        case .green: return age < 5 ? "Running · checked just now" : "Running · last checked \(age) s ago"
        case .waking: return "Waking up"
        case .amber: return "May be stuck · no sign of life for \(age / 60) min"
        case .red:
            if !ProcessCheck.isAlive(pid: beat.pid, startedAt: ISOTime.date(beat.started_at)) {
                return "Stopped · last seen \(age / 60) min ago"
            }
            return "Not answering · no sign of life for \(age / 60) min"
        case .unknown: return "Unknown"
        }
    }

    /// The fix beside the line it fixes, unless the notice above already offers the same button.
    @ViewBuilder func buttons(_ grade: HealthGrade) -> some View {
        let notice = model.notice
        // Background work is not optional (decisions.md A19): there is no Turn Off, and the app starts it by itself.
        switch model.runtimeStatus {
        case .requiresApproval:
            if notice?.loginItems != true { Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() } }
        case .enabled:
            if (grade == .red || grade == .amber || model.startFailure != nil || model.connectionProblem != nil
                || model.staleRuntimeBuild != nil) && !model.starting && notice?.restart != true {
                Button("Restart") { model.restart() }
            }
        default:
            if !model.starting && model.statusGrade != .green && notice?.restart != true { Button("Restart") { model.restart() } }
        }
    }

    @ViewBuilder func clerkLine(_ beat: Heartbeat) -> some View {
        if let m = beat.model {
            let words: [String: String] = [
                "available": "Available on this Mac",
                "deviceNotEligible": "This Mac cannot run Apple Intelligence. Notes still become cards, with less help.",
                "appleIntelligenceNotEnabled": "Off. Notes still become cards, with less help; turn it on in System Settings › Apple Intelligence & Siri for more.",
                "modelNotReady": "Still downloading. Notes still become cards meanwhile, with less help.",
            ]
            Text(words[m.availability] ?? m.availability)
        } else {
            Text("Not checked yet").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder func alertsLine(_ beat: Heartbeat) -> some View {
        if let alerts = beat.alerts, alerts.authorized {
            Text("Allowed")
        } else {
            Text("Off, so Sprava cannot warn you when something stops. Turn them on in System Settings › Notifications › Sprava.")
                .foregroundStyle(Self.broken)
        }
    }
}

/// The sidebar's status line, kept current whichever page is open. Red with a symbol when something breaks.
struct HealthStatusLine: View {
    @ObservedObject var health: HealthModel
    let selected: Bool
    let updated: String
    let open: () -> Void

    var body: some View {
        let summary = health.summary
        Button(action: open) {
            HStack(spacing: 6) {
                if summary.level == .trouble {
                    Image(systemName: NoticeLevel.broken.symbol).foregroundStyle(NoticeLevel.broken.color)
                } else {
                    Circle().fill(Self.color(summary.level)).frame(width: 8, height: 8)
                }
                Text("Health").fontWeight(selected ? .semibold : .regular)
                Text(verbatim: summary.word)
                    .foregroundStyle(summary.level == .trouble ? NoticeLevel.broken.color
                        : summary.level == .needsYou ? NoticeLevel.needsYou.color : .secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Open Health. Binders updated \(updated).")
        .accessibilityLabel("Health: \(summary.word)")
        .accessibilityHint("Opens Health. Binders updated \(updated).")
    }

    private static func color(_ level: HealthSummary.Level) -> Color {
        switch level {
        case .running: .green
        case .waking: .blue
        case .starting: .gray
        case .needsYou: NoticeLevel.needsYou.color
        case .trouble: NoticeLevel.broken.color
        }
    }
}

/// The line for runtime trouble the app cannot fix alone (decisions.md A19), above every page and first on Health: the
/// Login Items approval only the person can give, or why starting failed. Nothing is opened for the person; the button
/// is theirs to press. On Health it offers the support details in place of a way to Health.
struct RuntimeBanner: View {
    @ObservedObject var health: HealthModel
    var openHealth: (() -> Void)? = nil
    var inset = true
    var details: (() -> Void)? = nil

    var body: some View {
        if let notice = health.notice {
            Notice(level: notice.level, title: notice.title, detail: notice.detail) {
                if notice.loginItems { Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() } }
                if notice.restart {
                    Button("Restart") { health.restart() }.accessibilityLabel("Restart Sprava's background part")
                }
                if notice.level == .broken {
                    if let openHealth { Button("Open Health", action: openHealth) }
                    if let details { Button("Details for Support", action: details) }
                }
            }
            .padding(inset ? [.horizontal, .top] : [], 16)
        }
    }
}

/// One background job in plain words; its fix beside it when restarting is what helps.
struct JobLine: View {
    let key: String
    let job: Heartbeat.Job
    let beat: Heartbeat
    let lastWake: Date?
    let now: Date
    var restart: (() -> Void)? = nil

    var body: some View {
        let started = ISOTime.date(beat.started_at) ?? now
        let wake = [lastWake, ISOTime.date(beat.last_wake_at)].compactMap { $0 }.max()
        let grade = HealthGrade.job(job, key: key, startedAt: started, lastWake: wake, now: now)
        let words = JobWords.of(job, key: key, grade: grade, now: now)
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(grade.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(words.name)
                    Spacer()
                    Text(words.lastRan).foregroundStyle(.secondary)
                }
                if let problem = words.problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            if words.restartHelps, let restart {
                Button("Restart", action: restart).controlSize(.small).accessibilityLabel("Restart Sprava's background part")
            }
        }
    }
}
