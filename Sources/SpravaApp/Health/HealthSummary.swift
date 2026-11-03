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
        var runtime = HealthGrade.green
        var jobs: [HealthGrade] = []
        var backupFailed = false
        var backupOld = false
        var backupVeryOld = false
        var backupSettingsUnreadable = false
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
        if facts.jobs.contains(.amber) || facts.backupOld || facts.alertsOff || facts.otherFindings {
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
        if facts.backupVeryOld { return "A binder has not been backed up for more than a week." }
        return nil
    }
}

extension HealthModel {
    var summary: HealthSummary {
        var facts = HealthSummary.Facts()
        facts.starting = starting
        facts.needsApproval = runtimeStatus == .requiresApproval || keeper.state == .needsApproval
        facts.runtime = statusGrade
        if case .success(let beat) = heartbeat {
            let started = ISOTime.date(beat.started_at) ?? now
            let wake = [lastWake, ISOTime.date(beat.last_wake_at)].compactMap { $0 }.max()
            facts.jobs = beat.jobs.map { HealthGrade.job($0.value, key: $0.key, startedAt: started, lastWake: wake, now: now) }
            facts.alertsOff = beat.alerts?.authorized != true
        }
        facts.backupSettingsUnreadable = backupSettingsError != nil
        facts.backupFailed = backups.contains { $0.error != nil }
        // A binder not backed up yet has no age: a backup newly set up is not a failure.
        let ages = backups.compactMap { $0.at.map { now.timeIntervalSince($0) } }
        facts.backupVeryOld = ages.contains { $0 > 7 * 86_400 }
        facts.backupOld = ages.contains { $0 > 48 * 3600 }
        facts.otherFindings = findings.contains { $0.level == .fix } || deviceIDError != nil
            || watcherRepairFailure != nil || staleRuntimeBuild != nil
        return .of(facts)
    }
}
