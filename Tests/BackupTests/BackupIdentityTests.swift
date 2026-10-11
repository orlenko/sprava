@testable import Backup
import Darwin
import Foundation
import Testing

/// Backup ids: made once, kept in the binder, held by one folder at a time, never shared by a copy, and reassigned
/// safely across interruptions. Binders live in temporary folders only; nothing here runs restic. Invented data only.
@Suite struct BackupIdentityTests {
    func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-identity-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Backup ids

    @Test func aBinderThatIsGoneGetsNoBackupID() throws {
        let base = try temp("gone")
        let gone = base.appendingPathComponent("moved-away/Estate", isDirectory: true)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(gone) }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("moved-away").path))
    }

    @Test func aBackupIDThatCannotBeReadIsNeverReplaced() throws {
        let folder = try temp("unreadable-id")
        let sprava = folder.appendingPathComponent(".sprava")
        let url = sprava.appendingPathComponent("backup-id")
        try FileManager.default.createDirectory(at: sprava, withIntermediateDirectories: true)

        // A FIFO is refused without waiting on it.
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(folder) }
        #expect(Backup.existingBackupID(folder) == nil)
        try FileManager.default.removeItem(at: url)

        // One that cannot be read, or holds something else, is left as it is.
        let id = "0123456789abcdef0123456789abcdef\n"
        try Data(id.utf8).write(to: url)
        chmod(url.path, 0o000)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(folder) }
        chmod(url.path, 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == id)
        try Data("invented, not an id".utf8).write(to: url)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(folder) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "invented, not an id")

        // None at all: one is made, and kept.
        try FileManager.default.removeItem(at: url)
        let made = try Backup.backupID(folder)
        #expect(try Backup.backupID(folder) == made)
        #expect(Backup.existingBackupID(folder) == made)
    }

    @Test func anExistingBackupIDIsReadOnlyAndRefusesLinks() throws {
        let folder = try temp("existing-id")
        #expect(Backup.existingBackupID(folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava").path))
        let id = try Backup.backupID(folder)
        #expect(Backup.existingBackupID(folder) == id)

        // A backup-id that is a link to another binder's id is refused, and left as it is.
        let other = folder.appendingPathComponent("other-id")
        try Data("0123456789abcdef0123456789abcdef\n".utf8).write(to: other)
        let url = folder.appendingPathComponent(".sprava/backup-id")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: other.path)
        #expect(Backup.existingBackupID(folder) == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == other.path)

        // A .sprava folder that is a link is refused too.
        let elsewhere = folder.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("0123456789abcdef0123456789abcdef\n".utf8).write(to: elsewhere.appendingPathComponent("backup-id"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".sprava"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent(".sprava").path, withDestinationPath: elsewhere.path)
        #expect(Backup.existingBackupID(folder) == nil)
    }

    @Test func aCopyCannotClaimItsOriginalsIDUntilItHasItsOwn() throws {
        let base = try temp("copy")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let id = try Backup.backupID(original)
        let copy = base.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        #expect(try b.claim(original, &st) == id)
        try b.save(st)
        #expect(throws: Backup.SharedBackupID.self) { _ = try b.claim(copy, &st) }
        #expect(st.binders[id]?.path == original.standardizedFileURL.path)

        // The original keeps its id; the copy gets its own, recorded before it is written.
        #expect(throws: Backup.Failure.self) { try b.giveOwnBackupID(original) }
        let own = try b.giveOwnBackupID(copy)
        #expect(own != id && Backup.existingBackupID(copy) == own)
        #expect(try b.state().binders[own]?.path == copy.standardizedFileURL.path)
        #expect(try b.claim(copy, &st) == own)
    }

    @Test func aCopyCannotClaimAnIDWhoseRecordedVolumeIsUnavailable() throws {
        let base = try temp("unavailable-owner")
        let copy = base.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.appendingPathComponent(".sprava"), withIntermediateDirectories: true)
        let id = "0123456789abcdef0123456789abcdef"
        try Data((id + "\n").utf8).write(to: copy.appendingPathComponent(".sprava/backup-id"))
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        st.binders[id] = .init(path: "/Volumes/Invented-Disconnected-\(UUID().uuidString)/Binders/Original")
        #expect(throws: Backup.SharedBackupID.self) { _ = try b.claim(copy, &st) }
        #expect(st.binders[id]?.path?.hasSuffix("/Original") == true)
    }

    @Test func aBinderWhoseAncestorMovedTakesItsIDAlong() throws {
        let base = try temp("ancestor")
        let original = base.appendingPathComponent("Projects/Binder", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let id = try Backup.backupID(original)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        _ = try b.claim(original, &st)
        // The whole Projects folder is renamed: the binder's old parent is gone too.
        try FileManager.default.moveItem(at: base.appendingPathComponent("Projects"), to: base.appendingPathComponent("Archive"))
        let moved = base.appendingPathComponent("Archive/Binder", isDirectory: true)
        #expect(Backup.folderEntry(original) == .missing)
        #expect(try b.claim(moved, &st) == id)
        #expect(st.binders[id]?.path == moved.standardizedFileURL.path)
        // A disk that is away is not a move.
        let away = URL(fileURLWithPath: "/Volumes/Invented-Away-\(UUID().uuidString)/Binders/Estate", isDirectory: true)
        #expect(Backup.folderEntry(away) == .unavailable)
    }

    @Test func anInterruptedReassignmentIsFinishedNotRepeated() throws {
        let base = try temp("reassign")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        let old = try b.claim(original, &st)
        try b.save(st)
        let copy = base.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        // The new id is recorded, then writing it into the copy fails.
        let sprava = copy.appendingPathComponent(".sprava")
        chmod(sprava.path, 0o500)
        #expect(throws: (any Error).self) { try b.giveOwnBackupID(copy) }
        chmod(sprava.path, 0o700)
        #expect(Backup.existingBackupID(copy) == old)
        let pending = try #require(try b.state().binders.keys.first { $0 != old })
        #expect(try b.giveOwnBackupID(copy) == pending)
        #expect(try b.state().binders.count == 2)
    }

    @Test func anEmptyRecordOfAMovedBinderIsNeverTakenForAPendingReassignment() throws {
        let base = try temp("empty-record")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        let source = try b.claim(original, &st)
        // Another binder was claimed at Place, never backed up, then moved away; a copy of Original now sits there.
        let place = base.appendingPathComponent("Place", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let earlier = try b.claim(place, &st)
        try b.save(st)
        try FileManager.default.moveItem(at: place, to: base.appendingPathComponent("Elsewhere"))
        try FileManager.default.copyItem(at: original, to: place)
        let own = try b.giveOwnBackupID(place)
        #expect(own != earlier && own != source)
        #expect(Backup.existingBackupID(base.appendingPathComponent("Elsewhere")) == earlier)
        #expect(try b.state().reassigning.isEmpty)
    }

    @Test func aFileWhereTheParentWasMeansTheBinderIsGone() throws {
        let base = try temp("enotdir")
        try Data("invented".utf8).write(to: base.appendingPathComponent("Projects"))
        #expect(Backup.folderEntry(base.appendingPathComponent("Projects/Binder", isDirectory: true)) == .missing)
    }

    @Test func aFileWhereTheBinderWasLetsTheMovedBinderKeepItsID() throws {
        let base = try temp("file-in-place")
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        for replaceParent in [false, true] {
            let original = base.appendingPathComponent("Projects-\(replaceParent)/Binder", isDirectory: true)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            var st = Backup.State()
            let id = try b.claim(original, &st)
            let moved = base.appendingPathComponent("Archive-\(replaceParent)", isDirectory: true)
            try FileManager.default.moveItem(at: original, to: moved)
            // A file now sits where the binder, or its parent folder, was.
            let replaced = replaceParent ? original.deletingLastPathComponent() : original
            if replaceParent { try FileManager.default.removeItem(at: replaced) }
            try Data("invented".utf8).write(to: replaced)
            #expect(try b.claim(moved, &st) == id)
            #expect(st.binders[id]?.path == moved.standardizedFileURL.path)
        }
    }

    @Test func aReassignmentThatWroteItsIDIsFinishedOnRetry() throws {
        let base = try temp("reassigned")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        let old = try b.claim(original, &st)
        let copy = base.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        // As if the process stopped after writing the copy's new id, before clearing the reassignment.
        let new = "0123456789abcdef0123456789abcdef"
        st.binders[new] = .init(path: copy.standardizedFileURL.path)
        st.reassigning[Backup.realPath(copy)] = .init(from: old, id: new, folder: Backup.folderIdentity(copy))
        try b.save(st)
        try Backup.writeBackupID(new, into: copy, creating: false)
        #expect(try b.giveOwnBackupID(copy) == new)
        #expect(try b.state().reassigning.isEmpty)
    }

    @Test func aBinderReachedThroughALinkOrWritableByItsGroupGetsAnID() throws {
        let base = try temp("binder-roots")
        let real = base.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        chmod(real.path, 0o775)
        let link = base.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let id = try Backup.backupID(link)
        #expect(Backup.existingBackupID(real) == id)
        #expect(try Backup.backupID(link) == id)
        #expect(try Backup.keepRootMetadata(link).mode == 0o775)
    }

    @Test func aBinderBehindALinkToADiskThatIsAwayKeepsItsID() throws {
        let base = try temp("linked-away")
        // Projects is a link to a folder on a disk that is not connected now.
        try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("Projects").path,
                                                   withDestinationPath: "/Volumes/Invented-Away-\(UUID().uuidString)/Projects")
        let recorded = base.appendingPathComponent("Projects/Binder", isDirectory: true)
        #expect(Backup.folderEntry(recorded) == .unavailable)
        // Pointed at a file instead, the link proves the binder cannot be there.
        try Data("invented".utf8).write(to: base.appendingPathComponent("a-file"))
        try FileManager.default.removeItem(at: base.appendingPathComponent("Projects"))
        try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("Projects").path, withDestinationPath: "a-file")
        #expect(Backup.folderEntry(recorded) == .missing)
        // A file at a parent's path still means the binder is gone; a working link to a folder is followed.
        let real = base.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("Binder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("Shortcut"), withDestinationURL: real)
        #expect(Backup.folderEntry(base.appendingPathComponent("Shortcut/Binder", isDirectory: true)) == .present)
        #expect(Backup.folderEntry(base.appendingPathComponent("Shortcut/Gone", isDirectory: true)) == .missing)
    }

    @Test func twoCopiesKeepTheirOwnPendingReassignments() throws {
        let base = try temp("two-copies")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        _ = try b.claim(original, &st)
        try b.save(st)
        let first = base.appendingPathComponent("First", isDirectory: true), second = base.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: first)
        try FileManager.default.copyItem(at: original, to: second)
        chmod(first.appendingPathComponent(".sprava").path, 0o500)
        #expect(throws: (any Error).self) { try b.giveOwnBackupID(first) }
        chmod(first.appendingPathComponent(".sprava").path, 0o700)
        let pending = try #require(try b.state().reassigning[Backup.realPath(first)]?.id)
        let secondID = try b.giveOwnBackupID(second)
        #expect(try b.giveOwnBackupID(first) == pending)
        #expect(secondID != pending)
        #expect(try b.state().binders.count == 3 && b.state().reassigning.isEmpty)
    }

    @Test func aStaleReassignmentNeverHandsOutAnIDThatMovedOn() throws {
        let base = try temp("stale-reassignment")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        let old = try b.claim(original, &st)
        let a = base.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: a)
        // The copy at A got its new id N written, and the process stopped before clearing the reassignment.
        let n = "0123456789abcdef0123456789abcdef"
        st.binders[n] = .init(path: a.standardizedFileURL.path)
        st.reassigning[Backup.realPath(a)] = .init(from: old, id: n, folder: Backup.folderIdentity(a))
        try b.save(st)
        try Backup.writeBackupID(n, into: a, creating: false)
        // A moves to B; another copy of the original then sits at A, before or after B is claimed.
        let moved = base.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.moveItem(at: a, to: moved)
        try FileManager.default.copyItem(at: original, to: a)
        let own = try b.giveOwnBackupID(a)
        #expect(own != n && own != old)
        st = try b.state()
        #expect(try b.claim(moved, &st) == n)
        #expect(st.binders[n]?.path == moved.standardizedFileURL.path)
    }

    @Test func aReplacementAtAReassignedPathNeitherFinishesNorAbandonsBadly() throws {
        let base = try temp("replacement-at-path")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        let old = try b.claim(original, &st)
        try b.save(st)
        let a = base.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: a)

        // The reservation is recorded, and writing it into A fails; A is then replaced by another copy.
        chmod(a.appendingPathComponent(".sprava").path, 0o500)
        #expect(throws: (any Error).self) { try b.giveOwnBackupID(a) }
        chmod(a.appendingPathComponent(".sprava").path, 0o700)
        let abandoned = try #require(try b.state().reassigning[Backup.realPath(a)]?.id)
        try FileManager.default.removeItem(at: a)
        try FileManager.default.copyItem(at: original, to: a)
        let own = try b.giveOwnBackupID(a)
        #expect(own != abandoned && own != old)
        // The abandoned reservation leaves no phantom record behind.
        #expect(try b.state().binders[abandoned] == nil)
        #expect(try b.state().binders.count == 2)

        // A copy that holds a finished reassignment's id at its path, but is not the folder that was reassigned,
        // does not finish it.
        let n = "0123456789abcdef0123456789abcdef"
        let c = base.appendingPathComponent("C", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: c)
        st = try b.state()
        st.binders[n] = .init(path: c.standardizedFileURL.path)
        st.reassigning[Backup.realPath(c)] = .init(from: old, id: n, folder: "0:0")
        try b.save(st)
        try Backup.writeBackupID(n, into: c, creating: false)
        #expect(throws: Backup.Failure.self) { try b.giveOwnBackupID(c) }
        #expect(try b.state().reassigning[Backup.realPath(c)] != nil)
    }

    @Test func aCaseOnlyRenameIsTheSameBinder() throws {
        let base = try temp("case-rename")
        let original = base.appendingPathComponent("Binder", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let renamed = base.appendingPathComponent("binder", isDirectory: true)
        // Only on a case-insensitive volume do both spellings name one folder.
        var info = stat()
        guard stat(renamed.path, &info) == 0 else { return }
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        let id = try b.claim(original, &st)
        try FileManager.default.moveItem(at: original, to: base.appendingPathComponent("tmp-rename"))
        try FileManager.default.moveItem(at: base.appendingPathComponent("tmp-rename"), to: renamed)
        #expect(try b.claim(renamed, &st) == id)
    }

    @Test func anIDThatIsThereIsFlushedBeforeItCounts() throws {
        let folder = try temp("flush-existing")
        let id = try Backup.backupID(folder)
        // Read again (as a retry would after a failed flush): it is flushed and returned unchanged.
        #expect(try Backup.backupID(folder) == id)
    }

    @Test func aCopyMovedAfterItsIDWasWrittenFinishesItsReassignment() throws {
        let base = try temp("moved-after-write")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        let old = try b.claim(original, &st)
        let copy = base.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        let n = "0123456789abcdef0123456789abcdef"
        st.binders[n] = .init(path: copy.standardizedFileURL.path)
        st.reassigning[Backup.realPath(copy)] = .init(from: old, id: n, folder: Backup.folderIdentity(copy))
        try b.save(st)
        try Backup.writeBackupID(n, into: copy, creating: false)
        let moved = base.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: copy, to: moved)
        #expect(try b.giveOwnBackupID(moved) == n)
        let after = try b.state()
        #expect(after.reassigning.isEmpty && after.binders.count == 2)
        #expect(after.binders[n]?.path == moved.standardizedFileURL.path)
    }

    @Test func aCopyMovedBeforeItsRetryKeepsItsReservation() throws {
        let base = try temp("moved-before-retry")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        _ = try b.claim(original, &st)
        try b.save(st)
        let copy = base.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        chmod(copy.appendingPathComponent(".sprava").path, 0o500)
        #expect(throws: (any Error).self) { try b.giveOwnBackupID(copy) }
        chmod(copy.appendingPathComponent(".sprava").path, 0o700)
        let reserved = try #require(try b.state().reassigning[Backup.realPath(copy)]?.id)
        let moved = base.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: copy, to: moved)
        #expect(try b.giveOwnBackupID(moved) == reserved)
        let after = try b.state()
        #expect(after.reassigning.isEmpty && after.binders.count == 2)
        #expect(after.binders[reserved]?.path == moved.standardizedFileURL.path)
    }
}
