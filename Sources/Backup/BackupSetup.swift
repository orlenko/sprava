import Foundation

/// Setting up the mirror and the second backup (docs/backup.md §3.1, §5).
extension Backup {
    /// Sets up the mirror at `primary` with the key Sprava holds. An existing repository must open with that key.
    /// The settings name it only once it opens, so a failed change leaves the working mirror in place. Settings that
    /// cannot be read are never saved over. A mirror in or around the second backup is refused.
    ///
    /// A repository another Mac writes to (its marker names that Mac) is refused with `OtherMac`, unless the person
    /// chose to take it over (`takeOver`): then it is marked as this Mac's, and the other Mac's snapshots follow this
    /// Mac's retention from now on (decisions.md D44).
    public func setUp(primary: URL, iCloudKeychain: Bool, deviceID: String, takeOver: Bool = false) throws {
        var s = try settings()
        let oldPrimary = s.primary
        guard let binary = resticBinary else { throw Failure(message: "restic is missing from this installation") }
        try Self.refuseNestedRepository(primary)
        let mine = Self.macMark(deviceID)
        let marker = try Self.readMarker(primary)
        if let marker, marker.mac != mine, !takeOver { throw OtherMac(repository: "primary", name: marker.name) }
        s.primary = primary.standardizedFileURL.path
        s.iCloudKeychain = iCloudKeychain
        s.mac = mine
        if let marker, marker.mac != mine { s.formerMacs = Array(Set((s.formerMacs ?? []) + [marker.mac])).sorted() }
        // The pin is what keeps every later run to this restic (`engine`): a binary that cannot be read for it is refused.
        guard let digest = Restic.sha256(of: binary) else {
            throw Failure(message: "restic cannot be read to check it; nothing was changed")
        }
        s.resticSHA256 = digest
        // A new mirror must not share a fate with the second backup already chosen (§5), as setSecond requires. Setup
        // again at the same mirror (to trust an updated restic) checks nothing new, so a second disk that is away
        // does not stop it.
        // No mirror on record (a first setup, or settings that were lost while the state survived) counts as a change:
        // whatever the state says about binders is not known to be about this repository.
        let changing = oldPrimary != s.primary
        if let second = s.second, oldPrimary != s.primary {
            try refuseSharedFate(URL(fileURLWithPath: second, isDirectory: true), primary: primary)
        }
        let r = try engine(s.primary, settings: s, marked: false)
        // A repository made here is new and empty, also at the mirror's own path when the old one is gone: like a
        // move, it holds none of the binders' snapshots and none of an offloaded binder's pinned copies.
        let fresh = !r.isInitialized()
        // An offloaded binder's pinned copies are not in a new, empty repository; an existing one may be the old mirror
        // found again after the settings were lost, so it is accepted, with every record reset.
        if fresh || (oldPrimary != nil && changing) { try refuseMovingOffloadedBinders() }
        // With no mirror on record, an existing repository is accepted only if it holds every offloaded binder's
        // pinned snapshot: one that opens with the key may still be another repository.
        if !fresh, oldPrimary == nil { try refuseMissingPins(in: r) { $0.snapshot } }
        // A repository this setup makes in a folder that was not there is taken away again if the place is refused.
        let wasThere = FileManager.default.fileExists(atPath: r.repository.path)
        if fresh {
            try r.initRepository()
        } else {
            _ = try r.snapshots()   // throws when the key does not open it
        }
        let upload = uploadCheck(r.repository)
        if upload == .notInICloud || upload == .notChecked {
            if !wasThere { try? FileManager.default.removeItem(at: r.repository) }
            throw Failure(message: upload == .notChecked
                ? "the backup mirror's iCloud location could not be checked; nothing was changed. Try setup again"
                : "the backup mirror must be in iCloud Drive; nothing was changed")
        }
        // Marked only once the key opened it (or it was made here) and it is in iCloud Drive.
        try Self.mark(r.repository, as: mine, found: marker, fresh: fresh, in: &s)
        guard changing || fresh else { return try save(s) }
        let previous = try state()
        var st = previous
        for id in Array(st.binders.keys) {
            // Snapshots already in the old mirror stay there: record it, so expunging a document reaches it too.
            if changing, let oldPrimary { st.rememberRepositories([oldPrimary], for: id) }
            // Its last snapshot is not in this mirror: here each binder is due, and not shown as backed up.
            st.binders[id]?.snapshot = nil
            st.binders[id]?.at = nil
            st.binders[id]?.error = nil
        }
        // The old mirror's checks and drill say nothing about this one: it is due for each, from its first part.
        st.lastCheck = nil
        st.lastReadData = nil
        st.readDataPart = 0
        st.lastDrill = nil
        // Nor does its state snapshot or retention run: both are due in this one.
        st.stateSnapshotAt = nil
        st.lastForget = nil
        try saveTogether(st, s, previous: previous)
    }

    /// Records whether the key's last save reached iCloud Keychain. Marked unchecked before the key is stored and
    /// cleared only by a store that did reach it, so a crash in between leaves the warning standing.
    public func recordICloudKeychainChecked(_ checked: Bool) throws {
        var s = try settings()
        s.iCloudKeychainUnchecked = checked ? nil : true
        try save(s)
    }

    /// The second backup offloading requires: another cloud service's folder or an external disk. It must not
    /// share a fate with the mirror (§5): not the mirror's folder, not in or around it, and not in iCloud Drive.
    /// Like the mirror, a second backup another Mac writes to is refused with `OtherMac` unless taken over.
    public func setSecond(_ folder: URL, deviceID: String, takeOver: Bool = false) throws {
        var s = try settings()
        guard let primaryPath = s.primary else { throw Failure(message: "set up backup first") }
        let oldSecond = s.second
        try refuseSharedFate(folder, primary: URL(fileURLWithPath: primaryPath, isDirectory: true))
        try Self.refuseNestedRepository(folder)
        let mine = Self.macMark(deviceID)
        // Settings made before D44, or on another Mac, are this Mac's only once a run or a takeover marks them.
        guard s.mac == mine else { throw OtherMac(repository: "settings", name: nil) }
        let marker = try Self.readMarker(folder)
        if let marker, marker.mac != mine, !takeOver { throw OtherMac(repository: "second", name: marker.name) }
        if let marker, marker.mac != mine { s.formerMacs = Array(Set((s.formerMacs ?? []) + [marker.mac])).sorted() }
        s.second = folder.standardizedFileURL.path
        // A takeover still waiting for the former second backup does not carry over to this one.
        s.pendingTakeOver = nil
        let primary = try engine(s.primary)
        let second = try engine(s.second, settings: s, marked: false)
        // As for the mirror, a repository made here (at a new path, or at the old one when it is gone) is empty.
        let fresh = !second.isInitialized()
        let changing = oldSecond != s.second
        if fresh || (oldSecond != nil && changing) { try refuseMovingOffloadedBinders() }
        if !fresh, oldSecond == nil { try refuseMissingPins(in: second) { $0.secondSnapshot } }
        if fresh { try second.initRepository(copyingParametersFrom: (primary.repository, primary.key)) } else { _ = try second.snapshots() }
        try Self.mark(second.repository, as: mine, found: marker, fresh: fresh, in: &s)
        guard changing || fresh else { return try save(s) }
        let previous = try state()
        var st = previous
        // Older states may name the former second only in settings. Record it before the setting moves on.
        if changing, let oldSecond { for id in Array(st.binders.keys) { st.rememberRepositories([oldSecond], for: id) } }
        st.lastSecondCheck = nil
        st.lastSecondReadData = nil
        st.secondReadDataPart = 0
        st.lastSecondDrill = nil
        try saveTogether(st, s, previous: previous)
    }

    /// Marks a repository setup accepted as this Mac's. An existing one set up before D44 (no marker yet) brings its
    /// snapshots from before D44 into this Mac's retention, as a run that marks it does; so does one whose marker says
    /// its Mac had adopted them (a takeover, or this Mac's own after its settings were lost).
    static func mark(_ repository: URL, as mine: String, found marker: Marker?, fresh: Bool, in s: inout Settings) throws {
        if !fresh, marker == nil || marker?.legacy == true { adoptLegacy(&s, repository) }
        let legacy = adoptsLegacy(s, repository)
        guard marker?.mac != mine || (marker?.legacy == true) != legacy else { return }
        try writeMarker(mine, into: repository, legacy: legacy)
    }

    /// Saves the state for a new repository, then the settings naming it. If the settings cannot be saved, the
    /// earlier state is put back: the old repository stays configured, with its records as they were.
    func saveTogether(_ st: State, _ s: Settings, previous: State) throws {
        try save(st)
        do { try save(s) } catch {
            try? save(previous)
            throw error
        }
    }

    /// Every offloaded binder's pinned snapshot (`pin` of its record) must be in `r`, or nothing is changed.
    func refuseMissingPins(in r: Restic, _ pin: (Offloaded) -> String?) throws {
        // The pending records of binders that left (or are not here to leave) count as offloaded ones.
        let st = try state()
        let records = st.offloaded + st.offloads.filter { Self.leftWithoutRecord($0.key, $0.value) }.compactMap(\.value.record)
        guard !records.isEmpty else { return }
        // A record without that pin (an older one) cannot be checked, so it cannot be accepted either.
        let pins = records.map(pin)
        guard !pins.contains(nil) else {
            throw Failure(message: "an offloaded binder's copy cannot be checked in this repository; nothing was changed")
        }
        let held = Set(try r.snapshots().filter { $0.tags.contains("offloaded") }.map(\.id))
        guard pins.allSatisfy({ held.contains($0!) }) else {
            throw Failure(message: "this repository does not hold every offloaded binder's copy; nothing was changed")
        }
    }

    /// A leaving binder whose copies are all there is, though its record is not among the offloaded ones yet: its move
    /// to the Trash is recorded, or it is not at its path (a checkpoint restored on a Mac without it, a binder moved).
    static func leftWithoutRecord(_ id: String, _ job: InProgress) -> Bool {
        guard job.leavingTarget == nil else { return true }
        guard job.stage == "leaving", job.record != nil else { return false }
        let folder = URL(fileURLWithPath: job.path, isDirectory: true)
        return !(folderEntry(folder) == .present && isTheBinder(folder, id, job))
    }

    /// An offloaded binder's only copies are its pinned snapshots. Moving a repository must first copy and verify
    /// them in the new one; until that migration exists, a move is refused while any binder is offloaded.
    func refuseMovingOffloadedBinders() throws {
        // A binder whose move to the Trash is recorded is offloaded already, whatever cleanup is left; one leaving that
        // is not at its path (a checkpoint restored on another Mac, a binder moved) finishes from its copies alone.
        let st = try state()
        guard st.offloaded.isEmpty, !st.offloads.contains(where: { Self.leftWithoutRecord($0.key, $0.value) }) else {
            throw Failure(message: "an offloaded binder's only copies are in the current backups; restore it before moving them")
        }
    }
}
