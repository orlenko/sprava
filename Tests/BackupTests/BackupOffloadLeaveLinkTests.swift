@testable import Backup
import BinderFormat
import BinderStore
import Darwin
import Foundation
import Hub
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Offloading a binder reached through a link: the link and its chain, the binder's real place, a link removed or
/// retargeted while the binder waits to leave. Temporary folders and invented data only.
extension BackupOffloadLeaveTests {
    @Test func onlyALinkToTheBinderPlaceThatLeadsNowhereIsRemoved() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-leave-link-\(UUID().uuidString)")
        let place = base.appendingPathComponent("Estate", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: place)
        // It reaches a folder (another binder, put at the binder's place since): kept.
        try Backup.removeLink(link, to: place)
        #expect(FileManager.default.fileExists(atPath: link.path))
        // A replacement link to a disk that is away: kept, too.
        let away = base.appendingPathComponent("Away Alias")
        try FileManager.default.createSymbolicLink(atPath: away.path, withDestinationPath: "/Volumes/Invented-Away-\(UUID().uuidString)/Estate")
        try Backup.removeLink(away, to: place)
        var info = stat()
        #expect(lstat(away.path, &info) == 0)
        // The link to the binder's own place, which leads nowhere now: removed, also one reaching it through a long
        // chain of others.
        var chained = link
        for hop in 1...12 {
            let next = base.appendingPathComponent("Chained Alias \(hop)")
            try FileManager.default.createSymbolicLink(at: next, withDestinationURL: chained)
            chained = next
        }
        try FileManager.default.removeItem(at: place)
        try Backup.removeLink(chained, to: place)
        #expect(lstat(chained.path, &info) != 0)
        try Backup.removeLink(link, to: place)
        #expect(lstat(link.path, &info) != 0)
    }

    @Test func aLinkWhoseBinderMovedAwayLeadsNowhereButOneToADiskAwayWaits() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-leave-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // The binder the link led to was moved elsewhere on this Mac: its old place can be checked, and it is empty.
        let moved = base.appendingPathComponent("Moved Link")
        try FileManager.default.createSymbolicLink(atPath: moved.path, withDestinationPath: base.appendingPathComponent("Estate").path)
        #expect(Backup.folderEntry(moved) == .missing)
        // The link leads to a disk that is away: the binder may still be there.
        let away = base.appendingPathComponent("Away Link")
        try FileManager.default.createSymbolicLink(atPath: away.path, withDestinationPath: "/Volumes/Invented-Away-\(UUID().uuidString)/Estate")
        #expect(Backup.folderEntry(away) == .unavailable)
        // Through a chain of links, the end of the chain decides the same way.
        let chain = base.appendingPathComponent("Chain To Moved")
        try FileManager.default.createSymbolicLink(at: chain, withDestinationURL: moved)
        #expect(Backup.folderEntry(chain) == .missing)
        let awayChain = base.appendingPathComponent("Chain To Away")
        try FileManager.default.createSymbolicLink(at: awayChain, withDestinationURL: away)
        #expect(Backup.folderEntry(awayChain) == .unavailable)
    }

    @Test(.enabled(if: hasRestic)) func whileItWaitsToLeaveTheBinderKeepsItsRealPlaceAndItsID() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        let id = try Backup.backupID(e.folder)
        let shortcuts = e.base.appendingPathComponent("Shortcuts", isDirectory: true)
        try FileManager.default.createDirectory(at: shortcuts, withIntermediateDirectories: true)
        let link = shortcuts.appendingPathComponent(e.folder.lastPathComponent)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: e.folder)
        #expect(try b.offload(link, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) == .waitingForICloud(3))
        b.atStep = nil
        // The checkpoint's record already names the real place, not the link.
        #expect(try b.state().offloads[id]?.record?.originalPath == Backup.realPath(e.folder))
        // The binder is moved away and a changed copy of it put at its place: the copy is not the binder leaving.
        let moved = e.base.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.moveItem(at: e.folder, to: moved)
        try FileManager.default.copyItem(at: moved, to: e.folder)
        try Data("invented change".utf8).write(to: e.folder.appendingPathComponent("correspondence/notary/copy.pdf"))
        #expect(throws: Backup.SharedBackupID.self) { _ = try b.backUp(link, now: now) }
        #expect(throws: Backup.SharedBackupID.self) { _ = try b.backUp(e.folder, now: now) }
    }

    @Test(.enabled(if: hasRestic)) func aLinkedBinderStillAtItsRealPlaceIsNotTakenForGone() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        let id = try Backup.backupID(e.folder)
        let shortcuts = e.base.appendingPathComponent("Shortcuts", isDirectory: true)
        try FileManager.default.createDirectory(at: shortcuts, withIntermediateDirectories: true)
        let link = shortcuts.appendingPathComponent(e.folder.lastPathComponent)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: e.folder)
        #expect(try b.offload(link, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) == .waitingForICloud(3))
        b.atStep = nil
        // The link is removed while the binder waits; the binder itself is still at its own place.
        try FileManager.default.removeItem(at: link)
        waiting.on = false
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now, nameCollides: { _ in false }) }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.offloaded().isEmpty)
        #expect(try b.state().offloads[id] == nil)
    }

    @Test(.enabled(if: hasRestic)) func aRetargetedLinkDoesNotFinishTheOffloadOfTheBinderItLedTo() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        let id = try Backup.backupID(e.folder)
        let shortcuts = e.base.appendingPathComponent("Shortcuts", isDirectory: true)
        try FileManager.default.createDirectory(at: shortcuts, withIntermediateDirectories: true)
        let link = shortcuts.appendingPathComponent(e.folder.lastPathComponent)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: e.folder)
        #expect(try b.offload(link, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) == .waitingForICloud(3))
        b.atStep = nil
        // The link now leads to another folder; the binder is still at its own place.
        let other = e.base.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        waiting.on = false
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now, nameCollides: { _ in false }) }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.offloaded().isEmpty)
        #expect(try b.state().offloads[id] == nil)
    }
}
