import Backup
import Foundation
import Shelf
import SpravaKit

/// What the app's Health page shows, read in the app's own process so it works while the runtime is stopped
/// (architecture 3.3). Everything here only reads: no device id, backup id or state file is made or repaired, and
/// the backup key is never loaded. The app reads Sprava's support files through this, never directly.
public enum HealthSnapshot {
    /// The runtime's own records, cheap enough to read every few seconds.
    public struct Runtime: Sendable {
        public var heartbeat: Result<Heartbeat, Heartbeat.ReadError> = .failure(.missing)
        /// Starts recorded today in `runtime/state.json`, which rises even when no heartbeat is written.
        public var startsToday = 0
        /// The outside watcher's record (`runtime/watch.json`), as written.
        public var watchRecord: String?
        /// The last few lease refusals.
        public var refusals: [String] = []
        /// The person turned background work off.
        public var backgroundOff = false

        public init() {}
    }

    /// One binder's backup record, by name.
    public struct BackupLine: Sendable, Equatable {
        public let name: String
        public let at: Date?
        public let error: String?
    }

    /// The doctor and the backup records: slower, read about once a minute.
    public struct Checks: Sendable {
        public var findings: [Doctor.Finding] = []
        /// Why there are no findings, when the device id cannot be read: without it there is no telling which
        /// binders are this Mac's.
        public var deviceIDError: String?
        public var backupConfigured = false
        /// Why the backup settings cannot be read, if they cannot: not the same as backup not set up.
        public var backupSettingsError: String?
        /// Each adopted binder on the Shelf with its last backup, if any.
        public var backups: [BackupLine] = []

        public init() {}
    }

    public static func runtimeDirectory(support: URL) -> URL { support.appendingPathComponent("runtime", isDirectory: true) }

    public static func runtime(support: URL, today: String = CalendarDate.today().description) -> Runtime {
        let dir = runtimeDirectory(support: support)
        var out = Runtime()
        out.heartbeat = Heartbeat.read(dir.appendingPathComponent(Heartbeat.fileName))
        if case .ok(let data) = SafeFile.read(dir.appendingPathComponent("watch.json"), limit: 64 * 1024) {
            out.watchRecord = String(data: data, encoding: .utf8)
        }
        if case .ok(let data) = SafeFile.read(dir.appendingPathComponent("lease-refusals.log")), let log = String(data: data, encoding: .utf8) {
            out.refusals = Array(log.split(separator: "\n").suffix(3).map(String.init))
        }
        // A state file from another day counts nothing today; one that cannot be read counts nothing either.
        out.startsToday = (try? RuntimeState.read(dir, today: today))?.startsToday ?? 0
        out.backgroundOff = FileManager.default.fileExists(atPath: dir.appendingPathComponent("background-off").path)
        return out
    }

    /// The doctor's findings for the binders on the Shelf this Mac owns. Throws when the device id cannot be read;
    /// one that does not exist yet means no binder is this Mac's, so there is nothing to find.
    public static func doctorFindings(support: URL, deviceID: String? = nil) throws -> [Doctor.Finding] {
        guard let id = try deviceID ?? DeviceID.read(support.appendingPathComponent("device-id")) else { return [] }
        let url = LifeprojRegistry.defaultPath()
        let registry = FileManager.default.fileExists(atPath: url.path) ? try? LifeprojRegistry.load(from: url) : nil
        return Doctor.run(rows: ShelfStore(supportDirectory: support).rows(), deviceID: id, registry: registry, support: support)
    }

    public static func checks(support: URL) -> Checks {
        var out = Checks()
        do { out.findings = try doctorFindings(support: support) } catch { out.deviceIDError = "\(error)" }
        // The backup's records only; the key stays with the runtime (docs/backup.md §7).
        let backup = Backup(support: support, key: nil)
        do {
            out.backupConfigured = try backup.settings().primary != nil
        } catch {
            out.backupSettingsError = "\(error)"
        }
        let records = Dictionary(backup.status(checkUpload: false).binders.map { ($0.id, ($0.at, $0.error)) }, uniquingKeysWith: { a, _ in a })
        out.backups = ShelfStore(supportDirectory: support).rows().filter(\.teka.isAdopted).map { row in
            let record = Backup.existingBackupID(row.folder).flatMap { records[$0] }
            return BackupLine(name: row.name, at: record?.0.flatMap { ISOTime.date($0) }, error: record?.1)
        }
        return out
    }
}
