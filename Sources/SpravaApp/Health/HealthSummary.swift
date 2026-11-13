import Foundation
import Services
import SpravaKit

/// The sidebar's status line and the notice on every page (decisions.md D37), from what the Health page shows. A running
/// process is not enough to say Running: a stopped job or a failed backup is something breaking too. What a person may
/// leave as it is, such as backup never set up, does not change the line.
struct HealthSummary: Equatable {
    enum Level: Equatable { case running, waking, starting, needsYou, trouble }

    struct Facts: Equatable {
        var starting = false
        var needsApproval = false
        var startFailed = false
        var misplaced = false
        var runtime = HealthGrade.green
        var jobs: [HealthGrade] = []
        var backupFailed = false
        var backupOld = false
        var backupVeryOld = false
        var backupSettingsUnreadable = false
        var backupStateUnreadable = false
        var alertsOff = false
        var otherFindings = false
    }

    let level: Level
    let word: String
    /// What the notice on every page says, for trouble.
    var sentence: String?
    var detail: String?
    /// Whether restarting the background part is what could help.
    var restartHelps = false

    static func of(_ facts: Facts) -> HealthSummary {
        if facts.starting { return HealthSummary(level: .starting, word: "Starting…") }
        if facts.needsApproval { return HealthSummary(level: .needsYou, word: "Needs your approval") }
        if facts.startFailed {
            return HealthSummary(level: .trouble, word: "Trouble", sentence: "Sprava's background part could not be started.",
                                 restartHelps: true)
        }
        switch facts.runtime {
        case .red, .unknown:
            return HealthSummary(level: .trouble, word: facts.runtime == .red ? "Trouble" : "Not running",
                                 sentence: "Sprava's background part has stopped or is not answering.",
                                 detail: "New notes and files wait, and reminders do not fire, until it runs again.",
                                 restartHelps: true)
        default: break
        }
        if let trouble = worst(facts) { return HealthSummary(level: .trouble, word: "Trouble", sentence: trouble) }
        if facts.runtime == .amber { return HealthSummary(level: .needsYou, word: "May be stuck") }
        if facts.jobs.contains(.amber) || facts.backupOld || facts.alertsOff || facts.otherFindings
            || facts.misplaced {
            return HealthSummary(level: .needsYou, word: "Needs a look")
        }
        if facts.runtime == .waking { return HealthSummary(level: .waking, word: "Waking up") }
        return HealthSummary(level: .running, word: "Running")
    }

    private static func worst(_ facts: Facts) -> String? {
        let stopped = facts.jobs.filter { $0 == .red }.count
        if stopped == 1 { return "One of Sprava's background jobs has stopped working." }
        if stopped > 1 { return "\(stopped) of Sprava's background jobs have stopped working." }
        if facts.backupFailed { return "A backup failed." }
        if facts.backupSettingsUnreadable { return "Backup settings cannot be read." }
        if facts.backupStateUnreadable { return "Backup records cannot be read, so Sprava cannot tell when each binder was last backed up." }
        if facts.backupVeryOld { return "A binder has not been backed up for more than a week." }
        return nil
    }
}

extension HealthModel {
    /// One binder's backup, for its dot on the Health page and for the status line, so the two always agree: amber after
    /// 48 hours, red after 7 days (architecture 3.4). A binder not backed up yet has no age: a backup newly set up is not a
    /// failure. With backup not set up, a record left from an earlier setup says nothing.
    func grade(_ line: HealthSnapshot.BackupLine) -> HealthGrade {
        guard backupConfigured else { return .unknown }
        if line.error != nil || backupStateError != nil { return .red }
        guard let at = line.at else { return .unknown }
        let age = now.timeIntervalSince(at)
        return age > 7 * 86_400 ? .red : age > 48 * 3600 ? .amber : .green
    }

    var summaryFacts: HealthSummary.Facts {
        var facts = HealthSummary.Facts()
        // At launch nothing has been read yet: the starting screen covers this, and it is not "Not running".
        facts.starting = starting || keeper.launching
        facts.needsApproval = runtimeStatus == .requiresApproval || keeper.state == .needsApproval
        facts.startFailed = startFailure != nil
        facts.misplaced = locationProblem != nil
        facts.runtime = statusGrade
        if case .success(let beat) = heartbeat {
            let started = ISOTime.date(beat.started_at) ?? now
            let wake = [lastWake, ISOTime.date(beat.last_wake_at)].compactMap { $0 }.max()
            facts.jobs = beat.jobs.map { HealthGrade.job($0.value, key: $0.key, startedAt: started, lastWake: wake, now: now) }
            facts.alertsOff = beat.alerts?.authorized != true
        }
        facts.backupSettingsUnreadable = backupSettingsError != nil
        facts.backupFailed = backupConfigured && backups.contains { $0.error != nil }
        facts.backupStateUnreadable = backupConfigured && backupStateError != nil
        let grades = backups.map(grade)
        facts.backupVeryOld = !facts.backupFailed && !facts.backupStateUnreadable && grades.contains(.red)
        facts.backupOld = grades.contains(.amber)
        // Only what a binder needs. The app reads the checks without the hub folder or lifeproj's registry, so what
        // that says about the whole Mac would be there for everyone with an adopted binder (#573).
        facts.otherFindings = findings.contains { $0.level == .fix && $0.binder != nil } || deviceIDError != nil
            || watcherRepairFailure != nil || staleRuntimeBuild != nil
        return facts
    }

    var summary: HealthSummary { .of(summaryFacts) }
}
