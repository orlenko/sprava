import Foundation
import ServiceManagement
import Services
import SpravaKit

/// What the app does to have its background part running without asking (decisions.md A19): at launch, and when an
/// action finds the runtime not running. A pure decision, so it is tested without launchd.
enum RuntimeAutostart {
    /// The runtime agent's registration (`SMAppService.Status`); `notFound` counts as not registered.
    enum Registration: Equatable, Sendable { case enabled, notRegistered, requiresApproval }

    enum Step: Equatable, Sendable {
        /// A live heartbeat: nothing to do.
        case done
        /// Not registered: register the runtime and its watcher.
        case register
        /// Registered, no live heartbeat yet: give launchd a short wait for one.
        case wait
        /// Still no heartbeat: `launchctl kickstart -k`, falling back to registering again.
        case kickstart
        /// Unregister and register again. This also rewrites a login item record that points at a deleted copy of
        /// the app, which launchd keeps failing to start ("Invalid or missing Program/ProgramArguments", exit 78).
        case reregister
        /// macOS wants the person's approval in Login Items, which only they can give.
        case needsApproval
        /// This run's starts are used up.
        case giveUp
    }

    /// Starts one run makes before it gives up, so a run never loops.
    static let maxStarts = 2

    /// The next step, given the registration, whether a live heartbeat is there, the starts this run made and
    /// whether it has waited for a beat since its last start (or since it began).
    static func next(_ registration: Registration, live: Bool, starts: Int, waited: Bool) -> Step {
        if live { return .done }
        switch registration {
        case .requiresApproval:
            return .needsApproval
        case .notRegistered:
            return starts < maxStarts ? .register : .giveUp
        case .enabled:
            if !waited { return .wait }
            if starts >= maxStarts { return .giveUp }
            return starts == 0 ? .kickstart : .reregister
        }
    }

    /// A heartbeat is live when the process that wrote it is alive and it is under two minutes old (amber starts
    /// there, architecture 3.3); after a start, it must also come from the started runtime. Beats are written to the
    /// second, hence the second of grace.
    static func isLive(beatAt: Date, pidAlive: Bool, now: Date, since: Date?) -> Bool {
        guard pidAlive, now.timeIntervalSince(beatAt) < 120 else { return false }
        if let since { return beatAt > since.addingTimeInterval(-1) }
        return true
    }
}

/// Keeps Sprava's background part running: one bounded run at a time, shared by the app's launch, Health's Restart
/// and any action that finds the runtime not running.
@MainActor
final class RuntimeKeeper: ObservableObject {
    enum State: Equatable { case idle, starting, running, needsApproval, failed(String) }
    enum Outcome: Equatable { case running, needsApproval, failed(String) }

    /// The system calls behind a run. Each may block (launchd, a signature check), so each runs off the main actor.
    /// Tests stand them in; no test registers anything with launchd.
    struct System: Sendable {
        var registration: @Sendable () -> RuntimeAutostart.Registration
        /// Whether a live heartbeat is on disk, written after the date when there is one.
        var live: @Sendable (_ since: Date?) -> Bool
        /// Carries out a start step and returns what went wrong, in plain words, or nil.
        var start: @Sendable (RuntimeAutostart.Step) -> String?
    }

    static let noBeat = "Sprava's background part did not start: no heartbeat came after two restarts."

    @Published private(set) var state = State.idle
    let system: System
    /// How long a run waits for a beat after a start, and how often it looks.
    var beatWait: Duration = .seconds(30)
    var poll: Duration = .seconds(2)
    private var run: Task<Outcome, Never>?

    init(system: System) { self.system = system }

    /// Has the runtime running. After a run that failed, nothing is tried again until `restart()`, so a failure is
    /// reported, not retried on every launch of a screen or every failed request.
    func ensureRunning() async -> Outcome {
        if let run { return await run.value }
        if case .failed(let why) = state { return .failed(why) }
        return await perform(restartNow: false)
    }

    /// Health's Restart: a run that starts the runtime at once, even after a failed run.
    func restart() async -> Outcome {
        if let run { return await run.value }
        return await perform(restartNow: true)
    }

    private func perform(restartNow: Bool) async -> Outcome {
        let task = Task { await steps(waited: restartNow, restartNow: restartNow) }
        run = task
        let outcome = await task.value
        run = nil
        switch outcome {
        case .running: state = .running
        case .needsApproval: state = .needsApproval
        case .failed(let why): state = .failed(why)
        }
        return outcome
    }

    private func steps(waited startWaited: Bool, restartNow: Bool) async -> Outcome {
        let system = system
        var starts = 0
        var waited = startWaited
        var since: Date?
        while true {
            let after = since
            let (registration, live) = await Task.detached { (system.registration(), system.live(after)) }.value
            // An explicit Restart must also repair an alive process whose XPC listener is unreachable.
            let acceptExistingBeat = !(restartNow && starts == 0)
            let step = RuntimeAutostart.next(registration, live: live && acceptExistingBeat, starts: starts, waited: waited)
            switch step {
            case .done: return .running
            case .needsApproval: return .needsApproval
            case .giveUp: return .failed(Self.noBeat)
            case .wait:
                state = .starting
                waited = true
                if await beat(since: after) { return .running }
            case .register, .kickstart, .reregister:
                state = .starting
                starts += 1
                waited = false
                since = Date()
                if let failure = await Task.detached(operation: { system.start(step) }).value { return .failed(failure) }
            }
        }
    }

    private func beat(since: Date?) async -> Bool {
        let system = system
        let deadline = ContinuousClock.now + beatWait
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: poll)
            if await Task.detached(operation: { system.live(since) }).value { return true }
        }
        return false
    }
}

/// The real system calls: `SMAppService`, `launchctl` and the heartbeat on disk.
enum RuntimeStart {
    static let runtimePlist = "ca.orlenko.sprava.runtime.plist"
    static let watchPlist = "ca.orlenko.sprava.watch.plist"
    static let runtimeLabel = "ca.orlenko.sprava.runtime"

    /// Where the app runs from. Registering from a disk image or a translocated copy would point launchd at a
    /// path that disappears (architecture 3.1).
    static var locationProblem: String? {
        let path = Bundle.main.bundlePath
        if Bundle.main.bundleURL.pathExtension != "app" { return "Sprava is not running from an app bundle." }
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "Move Sprava to Applications first."
        }
        return nil
    }

    static func system(support: URL) -> RuntimeKeeper.System {
        RuntimeKeeper.System(
            registration: {
                switch SMAppService.agent(plistName: runtimePlist).status {
                case .enabled: .enabled
                case .requiresApproval: .requiresApproval
                default: .notRegistered
                }
            },
            live: { since in
                guard case .success(let beat) = HealthSnapshot.runtime(support: support).heartbeat,
                      let at = ISOTime.date(beat.beat_at) else { return false }
                let alive = ProcessCheck.isAlive(pid: beat.pid, startedAt: ISOTime.date(beat.started_at))
                return RuntimeAutostart.isLive(beatAt: at, pidAlive: alive, now: Date(), since: since)
            },
            start: { step in perform(step, support: support) })
    }

    /// Carries out one start step; nil when it went through.
    static func perform(_ step: RuntimeAutostart.Step, support: URL) -> String? {
        // Earlier builds let the person turn background work off with this marker; it would keep the outside watcher
        // silent (architecture 3.3), and background work is no longer optional.
        try? FileManager.default.removeItem(at: HealthSnapshot.runtimeDirectory(support: support).appendingPathComponent("background-off"))
        switch step {
        case .register: return register(again: false)
        case .kickstart: return kickstart() ? nil : register(again: true)
        case .reregister: return register(again: true)
        default: return nil
        }
    }

    /// `launchctl kickstart -k` restarts the job in place; false when launchctl refused or could not run.
    static func kickstart() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(getuid())/\(runtimeLabel)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Registers the runtime and its watcher, after the same refusals as ever: a disk image or translocated copy, and
    /// a bundle whose signature is not whole. `again` unregisters each first, so launchd's record is written anew.
    static func register(again: Bool) -> String? {
        if let problem = locationProblem { return problem }
        if let problem = BundleSignature.problem(at: Bundle.main.bundleURL) { return problem }
        do {
            for plist in [runtimePlist, watchPlist] {
                let service = SMAppService.agent(plistName: plist)
                if again { try? service.unregister() }
                try service.register()
            }
            return nil
        } catch {
            return BundleSignature.registerFailure(error)
        }
    }
}
