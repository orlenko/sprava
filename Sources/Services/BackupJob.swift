import Backup
import Foundation

/// The runtime's backup job (docs/backup.md §3.3): whether it has work it can do at all.
public enum BackupJob {
    /// nil when backup is set up and its key is here, so the job runs; otherwise the job's outcome. Settings that
    /// cannot be read are a failure Health shows, never "not set up". Settings that name a mirror while the key is
    /// not in the Keychain (deleted, or not readable now) stop every backup, so that is the job's error too: backup
    /// has no expected cadence, and a run recorded as skipped would leave Health green for good.
    public static func readiness(_ backup: Backup) -> JobOutcome? {
        let settings: Backup.Settings
        do { settings = try backup.settings() } catch {
            return .error(code: "backup_settings_unreadable", culprit: "backup/settings.json")
        }
        guard settings.primary != nil else { return .skipped }
        guard backup.key != nil else { return .error(code: "backup_key_unavailable", culprit: "the backup key is not in the Keychain") }
        return nil
    }
}
