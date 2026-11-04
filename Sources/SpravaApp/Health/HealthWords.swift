import Foundation
import ServiceManagement
import Services
import SpravaKit

/// The notice for runtime trouble, the same on every page and first on Health (decisions.md D37): what it says and which
/// of the existing buttons it offers.
struct RuntimeNotice: Equatable {
    let level: NoticeLevel
    let title: String
    var detail: String?
    var restart = false
    var loginItems = false
}

extension HealthModel {
    /// Nil while the launch's own starting screen shows the start, and when nothing needs the person.
    var notice: RuntimeNotice? {
        if keeper.launching { return nil }
        if starting {
            return RuntimeNotice(level: .info, title: "Starting Sprava's background part…",
                                 detail: "Binder creation waits until it can answer.")
        }
        if runtimeStatus == .requiresApproval || keeper.state == .needsApproval {
            return RuntimeNotice(level: .needsYou, title: "Sprava's background part is waiting for your approval.",
                                 detail: "Approve it in System Settings › General › Login Items. Changes wait until then.",
                                 loginItems: true)
        }
        if let failure = connectionProblem ?? startFailure {
            return RuntimeNotice(level: .broken, title: failure, restart: true)
        }
        if summary.level == .trouble, let sentence = summary.sentence {
            return RuntimeNotice(level: .broken, title: sentence, detail: summary.detail, restart: summary.restartHelps)
        }
        return nil
    }
}

/// One background job as Health shows it: a plain name, when it last ran, and, when it is not well, what is wrong and
/// whether restarting the background part is what helps. Codes, timings and the breaker go to the support details.
struct JobWords: Equatable {
    let name: String
    let lastRan: String
    /// What is wrong and what to do, when the job is not green.
    var problem: String?
    var restartHelps = false

    static let names: [String: String] = [
        "sentinel": "Checking deadlines",
        "alerts": "Checking notifications and Apple Intelligence",
        "summary": "Sending the daily summary",
        "hub": "Sharing binders with the hub",
        "capture": "Turning new notes into cards",
        "intake": "Reading new documents on this Mac",
        "clerk": "Drafting cards on this Mac",
        "dashboard": "Keeping DASHBOARD.md up to date",
        "backup": "Backing up binders",
    ]

    static func name(_ key: String) -> String {
        names[key] ?? key.replacingOccurrences(of: "_", with: " ")
    }

    static func of(_ job: Heartbeat.Job, key: String, grade: HealthGrade, now: Date) -> JobWords {
        let lastRan: String
        if job.last_outcome == "running" {
            lastRan = "running now"
        } else if let ran = [ISOTime.date(job.last_start), ISOTime.date(job.last_success), ISOTime.date(job.last_idle)]
            .compactMap({ $0 }).max() {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .short
            lastRan = "last ran \(relative.localizedString(for: min(ran, now), relativeTo: now))"
        } else {
            lastRan = "has not run yet"
        }
        var words = JobWords(name: name(key), lastRan: lastRan)
        guard grade != .green, grade != .waking, grade != .unknown else { return words }
        if job.breaker == "open" {
            words.problem = "Paused after failing several times in a row. Sprava tries it again by itself within the hour; "
                + "there is nothing to do in the app. If it stays paused, copy Details for support."
        } else if job.wedged {
            words.problem = "Stuck on its current run. Restarting the background part ends it."
            words.restartHelps = true
        } else if job.breaker == "half_open" {
            words.problem = "Being tried again after failing several times in a row. Sprava does this by itself."
        } else if job.consecutive_failures > 0 || ["error", "timeout"].contains(job.last_outcome) {
            words.problem = (job.last_outcome == "timeout" ? "The last run took too long." : "The last run failed.")
                + " Sprava tries again on the next run by itself."
        } else {
            words.problem = "Has not run when it should have. Restarting the background part may help."
            words.restartHelps = true
        }
        return words
    }
}

/// Everything Health used to show in code words, kept whole for a person helping with a problem. Never binder content:
/// a job's culprit is at most 200 characters and never names a binder or a file (architecture 3.7).
enum SupportDetails {
    static func text(heartbeat: Result<Heartbeat, Heartbeat.ReadError>, registration: String, startsToday: Int,
                     refusals: [String], watchRecord: String?) -> String {
        var lines: [String] = []
        lines.append("Registration: \(registration)")
        switch heartbeat {
        case .failure(let error):
            lines.append("Heartbeat: \(error == .missing ? "missing" : "unreadable")")
        case .success(let beat):
            var runtime = "pid \(beat.pid) · build \(beat.build) · restarts today \(max(beat.restarts_today ?? 0, startsToday - 1))"
            if beat.lease.duplicates_refused_today > 0 {
                runtime += " · duplicate starts refused \(beat.lease.duplicates_refused_today)"
            }
            lines.append(runtime)
            lines.append("Started \(beat.started_at) · last heartbeat \(beat.beat_at)"
                + (beat.last_wake_at.map { " · last wake \($0)" } ?? ""))
            if let model = beat.model {
                lines.append("Model: \(model.availability)" + (model.context_size.map { " · context \($0) tokens" } ?? ""))
            }
            if let alerts = beat.alerts {
                lines.append("Notifications: \(alerts.authorized ? "allowed" : "off") · checked \(alerts.checked_at)")
            }
            for key in beat.jobs.keys.sorted() {
                lines.append("\(key): " + job(beat.jobs[key]!))
            }
        }
        if let watchRecord { lines.append("Outside watcher: \(watchRecord)") }
        lines.append(contentsOf: refusals.map { "Refused: \($0)" })
        return lines.joined(separator: "\n")
    }

    static func job(_ job: Heartbeat.Job) -> String {
        var parts: [String] = [job.last_outcome]
        parts.append(job.last_success.map { "last success \($0)" } ?? "no success yet")
        if job.breaker != "closed" { parts.append("breaker \(job.breaker.replacingOccurrences(of: "_", with: "-"))") }
        if job.wedged { parts.append("wedged") }
        if job.consecutive_failures > 0 { parts.append("failures in a row \(job.consecutive_failures)") }
        if let error = job.last_error, job.consecutive_failures > 0 {
            parts.append("\(error.code)" + (error.culprit.map { ": \($0)" } ?? ""))
        }
        if let median = job.median_ms {
            parts.append("median \(median) ms · slowest \(job.slowest_of_twenty_ms ?? median) ms")
        }
        return parts.joined(separator: " · ")
    }

    static func registration(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
    }
}
