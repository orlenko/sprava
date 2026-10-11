import Foundation

/// Setting up the mirror and the second backup (docs/backup.md §3.1, §5).
extension Backup {
    /// Sets up the mirror at `primary` with the key Sprava holds. An existing repository must open with that key.
    /// The settings name it only once it opens, so a failed change leaves the working mirror in place. Settings that
    /// cannot be read are never saved over. A mirror in or around the second backup is refused.
    public func setUp(primary: URL, iCloudKeychain: Bool) throws {
        var s = try settings()
        let oldPrimary = s.primary
        guard let binary = resticBinary else { throw Failure(message: "restic is missing from this installation") }
        s.primary = primary.standardizedFileURL.path
        s.iCloudKeychain = iCloudKeychain
        // The pin is what keeps every later run to this restic (`engine`): a binary that cannot be read for it is refused.
        guard let digest = Restic.sha256(of: binary) else {
            throw Failure(message: "restic cannot be read to check it (\(binary.path)); nothing was changed")
        }
        s.resticSHA256 = digest
        // A new mirror must not share a fate with the second backup already chosen (§5), as setSecond requires. Setup
        // again at the same mirror (to trust an updated restic) checks nothing new, so a second disk that is away
        // does not stop it.
        let changing = oldPrimary.map { $0 != s.primary } ?? false
        if let second = s.second, oldPrimary != s.primary {
            try refuseSharedFate(URL(fileURLWithPath: second, isDirectory: true), primary: primary)
        }
        if changing { try refuseMovingOffloadedBinders() }
        let r = try engine(s.primary, settings: s)
        // A repository this setup makes in a folder that was not there is taken away again if the place is refused.
        let wasThere = FileManager.default.fileExists(atPath: r.repository.path)
        if r.isInitialized() {
            _ = try r.snapshots()   // throws when the key does not open it
        } else {
            try r.initRepository()
        }
        guard uploadCheck(r.repository) != .notInICloud else {
            if !wasThere { try? FileManager.default.removeItem(at: r.repository) }
            throw Failure(message: "the backup mirror must be in iCloud Drive; nothing was changed")
        }
        if changing, let oldPrimary {
            // Snapshots already in the old mirror stay there: record it, so expunging a document reaches it too.
            // Saving this first is harmless if saving the setting then fails.
            var st = try state()
            for id in Array(st.binders.keys) {
                st.rememberRepositories([oldPrimary], for: id)
                // Its last snapshot is in the old mirror: in the new one each binder is due, and not shown as backed up.
                st.binders[id]?.snapshot = nil
                st.binders[id]?.at = nil
            }
            // The old mirror's checks and drill say nothing about the new one: it is due for each, from its first part.
            st.lastCheck = nil
            st.lastReadData = nil
            st.readDataPart = 0
            st.lastDrill = nil
            try save(st)
        }
        try save(s)
    }

    /// The second backup offloading requires: another cloud service's folder or an external disk. It must not
    /// share a fate with the mirror (§5): not the mirror's folder, not in or around it, and not in iCloud Drive.
    public func setSecond(_ folder: URL) throws {
        var s = try settings()
        guard let primaryPath = s.primary else { throw Failure(message: "set up backup first") }
        let oldSecond = s.second
        try refuseSharedFate(folder, primary: URL(fileURLWithPath: primaryPath, isDirectory: true))
        s.second = folder.standardizedFileURL.path
        if let oldSecond, oldSecond != s.second { try refuseMovingOffloadedBinders() }
        let primary = try engine(s.primary)
        let second = try engine(s.second, settings: s)
        if second.isInitialized() { _ = try second.snapshots() } else { try second.initRepository(copyingParametersFrom: (primary.repository, primary.key)) }
        if let oldSecond, oldSecond != s.second {
            // Older states may name the former second only in settings. Record it before the setting moves on.
            var st = try state()
            for id in Array(st.binders.keys) { st.rememberRepositories([oldSecond], for: id) }
            st.lastSecondCheck = nil
            st.lastSecondReadData = nil
            st.secondReadDataPart = 0
            st.lastSecondDrill = nil
            try save(st)
        }
        try save(s)
    }

    /// An offloaded binder's only copies are its pinned snapshots. Moving a repository must first copy and verify
    /// them in the new one; until that migration exists, a move is refused while any binder is offloaded.
    func refuseMovingOffloadedBinders() throws {
        guard try state().offloaded.isEmpty else {
            throw Failure(message: "an offloaded binder's only copies are in the current backups; restore it before moving them")
        }
    }
}
