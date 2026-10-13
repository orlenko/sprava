import Backup
import BinderFormat
import Foundation
import Hub
import Shelf
import SpravaKit

/// Backup (docs/backup.md): first one request the app queued (offload, a restore drill, back up now), then the
/// scheduled work, which itself does nothing until something is due. The scheduled work runs after a request too,
/// so an offload left waiting for iCloud never holds up the other binders' backups and checks. Last, it starts the
/// check of whether iCloud has uploaded the mirror, which the backup status shows (`BackupUploadCheck`).
public enum BackupJob {
    /// `backup` is made by the caller for this run (it reads the key as it is now); `notify` tells the person how a
    /// request ended.
    public static func run(_ context: JobContext, backup: Backup, today: CalendarDate = .today(), now: Date = Date(),
                           uploadCheckPatience: TimeInterval = 120,
                           notify: (_ title: String, _ body: String, _ id: String) -> Void) -> JobOutcome {
        guard let commands = context.commands else { return context.noCommands }
        let original = backup
        let backup = BackupUploadGate.bounded(original, patience: uploadCheckPatience)
        let started = ContinuousClock.now
        // Settings that cannot be read are a failure Health shows, never "not set up".
        let configured: Bool
        do { configured = try backup.settings().primary != nil } catch {
            context.log("backup settings_unreadable")
            return .error(code: "backup_settings_unreadable", culprit: "backup/settings.json")
        }
        guard configured else { return .skipped }
        guard backup.key != nil else {
            context.log("backup key_unavailable")
            return .error(code: "backup_key", culprit: nil)
        }
        guard let rows = try? context.rows() else { return SentinelJob.shelfUnreadable }
        // An offloaded binder's hub slice is withdrawn by Sprava's record only when another binder here shares its name.
        let colliding = HubLane.collidingFolders(rows, today: today)
        let nameCollides = { (folder: URL) in colliding.contains(folder.standardizedFileURL.path) }
        let requests = BackupRequests(support: context.support)
        // The request and the scheduled work each change the backup's state one at a time with the setup and
        // second-backup commands (`BackupStateLock`); a command waiting gets its turn between them.
        let stateLock = BackupStateLock.of(backup.support)
        var requestOutcome = JobOutcome.ok
        var ranRequest = false
        do {
            if let request = try requests.next() {
                ranRequest = true
                do {
                    try stateLock.job {
                        try requests.run(request, backup: backup, deviceID: commands.deviceID, nameCollides: nameCollides, now: now)
                    }
                } catch {
                    // The queue could not record the request as running, or how it ended: reported, never "done".
                    context.log("backup request=\(request.kind) queue_unwritable")
                    requestOutcome = .error(code: "backup_requests_unwritable", culprit: request.kind)
                }
                let state = (try? requests.all())?.first { $0.id == request.id }?.state ?? "?"
                context.log("backup request=\(request.kind) state=\(state)")
                if state == "done" {
                    notify("Sprava", "Backup: \(request.kind.replacingOccurrences(of: "_", with: " ")) finished.", "backup-\(request.id)")
                }
                if state == "failed", requestOutcome == .ok { requestOutcome = .error(code: "backup_request_failed", culprit: request.kind) }
            }
        } catch {
            // A queue that cannot be read is left as it is, and reported; the scheduled work still runs.
            context.log("backup requests_unreadable")
            requestOutcome = .error(code: "backup_requests_unreadable", culprit: nil)
        }
        let m = stateLock.job { backup.maintain(rows: rows, deviceID: commands.deviceID, nameCollides: nameCollides, now: now) }
        if m.snapshots > 0 || m.failed > 0 || m.retention || m.checked {
            context.log("backup snapshots=\(m.snapshots) unchanged=\(m.unchanged) failed=\(m.failed) failed_parts=\(m.failedParts.joined(separator: ",")) state=\(m.stateSnapshot) retention=\(m.retention) checked=\(m.checked)")
        }
        // On a thread of its own, never awaited here, so a stalled iCloud never holds up this job or the next
        // (`BackupUploadCheck`). Its time is when the walk began.
        if let primary = try? backup.settings().primary {
            let elapsed = started.duration(to: ContinuousClock.now).components
            let at = now.addingTimeInterval(TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18)
            let check = BackupUploadCheck.of(backup.support).start(original, primary: primary,
                                                                   wrote: ranRequest || m.snapshots > 0 || m.stateSnapshot || m.retention,
                                                                   now: at) { context.log($0) }
            if check == .started(abandoned: true) { context.log("backup upload_check_abandoned") }
        }
        // Sprava's own state snapshot, retention and the check fail the job as a binder does (docs/backup.md §3.3).
        let culprit = "\(m.failed) failure(s)" + (m.failedParts.isEmpty ? " in binder backups" : ", including " + m.failedParts.joined(separator: ", "))
        return m.failed > 0 ? .error(code: "backup_failed", culprit: culprit) : requestOutcome
    }
}
