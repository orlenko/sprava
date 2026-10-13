import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

/// The backup job's scheduled work (docs/backup.md §3.3): each live binder this Mac manages hourly (a run that finds
/// nothing changed takes no snapshot), Sprava's own state daily, retention and a structure check weekly, a rotating
/// read-back monthly. Restore bookkeeping, forgetting and peeks join with their slices.
extension Backup {
    public struct Maintenance: Sendable, Equatable {
        public var snapshots = 0
        public var unchanged = 0
        public var failed = 0
        public var stateSnapshot = false
        public var retention = false
        public var checked = false
        /// What failed apart from the binders, by name (`backup_settings`, `backup_state`, `backup_key`, `offload`,
        /// `state_snapshot`, `retention`, `check`): each also counts in `failed` and stays due, so the next run tries
        /// it again.
        public var failedParts: [String] = []
        /// Folders not backed up because they hold another binder's backup id (`SharedBackupID`); each also counts in
        /// `failed`.
        public var sharedBackupIDs: [String] = []
        /// Folders of binders whose writes are blocked until the person approves a repair (`Teka.writesBlocked`): a
        /// backup writes into the binder (its backup id, its folder's metadata), so none is taken; each counts in
        /// `failed` until it is put right, so backups never stop in silence.
        public var blockedBinders: [String] = []

        public init() {}
    }

    static let hourly: TimeInterval = 3600
    static let daily: TimeInterval = 86_400
    static let weekly: TimeInterval = 7 * 86_400
    static let monthly: TimeInterval = 30 * 86_400

    /// Runs whatever is due. No binder lock is held through a restic run, which would hold up approvals for minutes;
    /// a write that lands during a run leaves the binder due, so the next run snapshots it again (`backUp`).
    /// Settings, state or a key that cannot be read stop all of it, as a failure; backup not set up is no work.
    /// `nameCollides` is the offload's question, for an offload that stopped while its binder was leaving.
    public func maintain(rows: [ShelfRow], deviceID: String, nameCollides: (URL) -> Bool, now: Date = Date()) -> Maintenance {
        var m = Maintenance()
        func older(_ iso: String?, than seconds: TimeInterval) -> Bool {
            guard let iso, let d = ISOTime.date(iso) else { return true }
            return now.timeIntervalSince(d) > seconds
        }
        func fail(_ part: String) {
            m.failed += 1
            if !m.failedParts.contains(part) { m.failedParts.append(part) }
        }
        let configured: Settings
        do { configured = try settings() } catch {
            fail("backup_settings")
            return m
        }
        guard configured.primary != nil else { return m }
        guard key != nil else {
            fail("backup_key")
            return m
        }
        guard let st = try? state() else {
            fail("backup_state")
            return m
        }
        // An offload interrupted while its binder was leaving is finished here, whatever became of its request.
        for (id, job) in st.offloads.sorted(by: { $0.key < $1.key }) where job.stage == "leaving" {
            if (try? continueOffload(id, now: now, nameCollides: nameCollides)) == nil { fail("offload") }
        }
        for row in rows where row.teka.isAdopted && Owner.device(of: row.folder) == deviceID {
            guard !row.teka.writesBlocked else {
                m.failed += 1
                m.blockedBinders.append(row.folder.standardizedFileURL.path)
                continue
            }
            // Read only, never through a link: `backUp` claims the id when it runs.
            if let id = Self.existingBackupID(row.folder) {
                // Only a binder on its way out is left alone. One whose offload failed or waits for iCloud is still
                // live and still changing, so it is backed up as usual; a change starts its offload over anyway.
                if st.offloads[id]?.stage == "leaving" { continue }
                guard older(st.binders[id]?.at, than: Self.hourly) else { continue }
            }
            do {
                let r = try backUp(row.folder, now: now)
                if r.snapshot == nil { m.unchanged += 1 } else { m.snapshots += 1 }
            } catch let shared as SharedBackupID {
                m.failed += 1
                m.sharedBackupIDs.append(shared.folder)
            } catch {
                m.failed += 1
            }
        }
        func due(_ field: (State) -> String?, _ seconds: TimeInterval) -> Bool {
            guard let current = try? state() else { return false }
            return older(field(current), than: seconds)
        }
        // Sprava's own state holds the offload records and other recovery state: a failed snapshot of it is a
        // failure like a binder's, and so is a failed retention run. Neither moves its date, so both stay due.
        if due(\.stateSnapshotAt, Self.daily) {
            if (try? backUpState(now: now)) != nil { m.stateSnapshot = true } else { fail("state_snapshot") }
        }
        if due(\.lastForget, Self.weekly) {
            if (try? applyRetention(now: now)) != nil { m.retention = true } else { fail("retention") }
        }
        // Each repository keeps its own dates, so a second backup that is away stays due while the mirror's check
        // still counts.
        let primaryDue = due(\.lastCheck, Self.weekly)
        let secondDue = configured.second != nil && due(\.lastSecondCheck, Self.weekly)
        if primaryDue || secondDue {
            let primaryReadData = primaryDue && due(\.lastReadData, Self.monthly)
            let secondReadData = secondDue && due(\.lastSecondReadData, Self.monthly)
            if (try? check(readPrimaryData: primaryReadData, readSecondData: secondReadData,
                           primary: primaryDue, second: secondDue, now: now)) != nil {
                m.checked = true
            } else {
                fail("check")
            }
        }
        return m
    }
}
