import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// Backing up: binder snapshots, Sprava's own state, retention, checks and the restore drill (docs/backup.md §3, §8).
extension Backup {
    // MARK: - Snapshots

    /// What a snapshot of Sprava's own state leaves out besides `excludes` (`backUpState`): the backup's own working
    /// folders, and the runtime's logs with their rotations (§3.2), by their paths in the support folder, never by
    /// extension: a capture's attachment may well end in `.log`. Anchored at the support folder as restic sees it
    /// (symbolic links resolved by realpath(3), which keeps /private where Foundation drops it), with the pattern
    /// characters in it taken literally.
    func stateExcludes() -> [String] {
        let resolved = realpath(support.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? Self.realPath(support)
        let root = resolved.map { "*?[\\".contains($0) ? "\\\($0)" : String($0) }.joined()
        return ["backup/cache", "backup/run", "backup/verify", "backup/peek"]
            + ["jobs.log", "lease-refusals.log"].flatMap { ["\(root)/runtime/\($0)", "\(root)/runtime/\($0).[0-9]*"] }
    }

    /// A mark for everything restic is to read. Comparing only the catalog and op log misses a document or intake
    /// file written while restic is traversing another directory, and could call that partial snapshot current.
    /// The binder folder's own metadata is part of it too (`keepRootMetadata`), so a change to it during the run
    /// leaves the binder due as well.
    static func writeMark(_ folder: URL) throws -> String { digest(try manifest(folder)) + " " + (try rootMetadata(folder)).entry }

    @discardableResult
    public func backUp(_ folder: URL, now: Date = Date()) throws -> Restic.BackupResult {
        let teka = Teka.read(folder)
        guard !teka.writesBlocked else {
            throw Failure(message: "this binder cannot be backed up until it is repaired: " + teka.reasons.joined(separator: "; "))
        }
        var st = try state()
        let id = try claim(folder, &st)
        let s = try settings()
        // The claim and repository are saved before restic writes anything under the id: a snapshot never exists
        // without an owner, nor without a durable record of every repository that may hold it.
        st.rememberRepositories([s.primary], for: id)
        try save(st)
        step("backup.claimed")
        do {
            try Self.keepRootMetadata(folder)
            let before = try Self.writeMark(folder)
            let result = try engine(s.primary).backup(folder, tags: ["sprava", "binder:\(id)"], excludes: Self.excludes)
            afterSnapshot?()
            step("backup.snapshotted")
            var rec = st.binders[id] ?? State.BinderRecord()
            if let snap = result.snapshot { rec.snapshot = snap }
            // restic reads one file at a time, so a write that landed during the run may be only partly in this
            // snapshot. The binder then stays due, and the next run takes another.
            if try Self.writeMark(folder) == before { rec.at = ISOTime.string(now) }
            rec.bytes = result.bytes
            rec.error = nil
            st.binders[id] = rec
            try save(st)
            return result
        } catch {
            st.binders[id, default: State.BinderRecord()].error = "\(error)"
            try? save(st)
            throw error
        }
    }

    /// Sprava's own state, minus the backup's cache and run files, and minus the runtime's logs (§3.2,
    /// `stateExcludes`).
    func writeStateSnapshot() throws {
        _ = try engine(settings().primary).backup(support, tags: ["sprava", "sprava-state"],
                                                  excludes: Self.excludes + stateExcludes())
    }

    public func backUpState(now: Date = Date()) throws {
        var st = try state()
        try writeStateSnapshot()
        st.stateSnapshotAt = ISOTime.string(now)
        try save(st)
    }

    /// Weekly forget and prune per binder, by the retention rule; offloaded snapshots are always kept.
    public func applyRetention(now: Date = Date()) throws {
        let s = try settings()
        var st = try state()
        // Sprava's own state snapshots follow the same rule as the binders', so a capture attachment deleted long ago
        // does not stay in them for ever.
        let tags = st.binders.keys.sorted().map { "binder:\($0)" } + ["sprava-state"]
        func apply(_ r: Restic) throws {
            for tag in tags {
                try r.forget(tag: tag, keepLast: s.keepLast, keepWithinDays: s.keepWithinDays,
                             keepMonthly: s.keepMonthly, keepYearly: s.keepYearly, prune: false)
            }
            try r.prune()
        }
        try apply(engine(s.primary))
        st.lastForget = ISOTime.string(now)
        try save(st)
        // The second backup holds pinned copies (always kept) and its own drill snapshots, which follow the rule too.
        // One that is away fails here and is tried with the next weekly run; the mirror's retention still counts.
        if s.second != nil {
            do { try apply(engine(s.second)) } catch {
                throw Failure(message: "retention could not run on the second backup (\(error))")
            }
        }
    }

    /// Weekly structure check; monthly, one twelfth of the data read back, rotating. The second backup holds the only
    /// other copy of an offloaded binder, so it is checked too (§5), with its own date: one that is away or damaged
    /// stays due and fails the check, while the mirror's check still counts.
    public func check(readData: Bool, now: Date = Date()) throws {
        try check(readPrimaryData: readData, readSecondData: readData, primary: true, second: true, now: now)
    }

    func check(readPrimaryData: Bool, readSecondData: Bool, primary: Bool, second: Bool, now: Date) throws {
        let s = try settings()
        var st = try state()
        func run(_ r: Restic, readData: Bool, part: Int) throws {
            if readData { try r.check(readDataSubset: "\(part)/12") } else { try r.check() }
        }
        var failure: Error?
        if primary {
            let part = st.readDataPart % 12 + 1
            do {
                try run(try engine(s.primary), readData: readPrimaryData, part: part)
                if readPrimaryData {
                    st.readDataPart = part
                    st.lastReadData = ISOTime.string(now)
                }
                st.lastCheck = ISOTime.string(now)
            } catch { failure = error }
        }
        if second, s.second != nil {
            let part = st.secondReadDataPart % 12 + 1
            do {
                try run(try engine(s.second), readData: readSecondData, part: part)
                if readSecondData {
                    st.secondReadDataPart = part
                    st.lastSecondReadData = ISOTime.string(now)
                }
                st.lastSecondCheck = ISOTime.string(now)
            } catch { failure = failure ?? Failure(message: "the second backup failed its check (\(error))") }
        }
        try save(st)
        if let failure { throw failure }
    }


    // MARK: - Restore drill (§8)

    public enum DrillRepository: String, Codable, Sendable { case primary, second }

    /// Backs the binder up, restores the snapshot into a private temporary folder, compares, and cleans up.
    public func drill(_ folder: URL, repository choice: DrillRepository = .primary, now: Date = Date()) throws {
        let teka = Teka.read(folder)
        guard !teka.writesBlocked else {
            throw Failure(message: "this binder cannot be used for a restore drill until it is repaired: " + teka.reasons.joined(separator: "; "))
        }
        let s = try settings()
        let path: String?
        switch choice {
        case .primary: path = s.primary
        case .second:
            guard s.second != nil else { throw Failure(message: "the second backup is not set up") }
            path = s.second
        }
        let repository = try engine(path)
        var claimed = try state()
        let id = try claim(folder, &claimed)
        claimed.rememberRepositories([path], for: id)
        try save(claimed)
        let root = try Self.keepRootMetadata(folder)
        // The snapshot this drill just took, by its id: the latest by time may be an older one taken under a clock
        // that was ahead.
        let taken = try repository.backup(folder, tags: ["sprava", "binder:\(id)"], excludes: Self.excludes, skipIfUnchanged: false)
        afterSnapshot?()
        guard let snap = taken.snapshot else { throw Failure(message: "no snapshot to restore") }
        let target = dir.appendingPathComponent("verify/drill-\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        try AtomicFile.makePrivateFolder(target)
        defer { try? FileManager.default.removeItem(at: target) }
        try repository.restore(snap, into: target)
        // The folder's own settings are compared too: the snapshot holds them as they were kept before it.
        guard try Self.manifest(target) == Self.manifest(folder), try Self.rootMetadata(folder) == root else {
            throw Failure(message: "the restored copy differs from the binder")
        }
        var st = try state()
        switch choice {
        case .primary:
            st.lastDrill = ISOTime.string(now)
            // The restored copy matched the binder as it is, so this snapshot in the mirror is the binder's backup.
            var record = st.binders[id] ?? State.BinderRecord()
            record.snapshot = snap
            record.at = ISOTime.string(now)
            record.bytes = taken.bytes
            record.error = nil
            st.binders[id] = record
        case .second: st.lastSecondDrill = ISOTime.string(now)
        }
        try save(st)
    }
}
