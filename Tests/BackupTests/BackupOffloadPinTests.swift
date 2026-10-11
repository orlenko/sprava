@testable import Backup
import BinderFormat
import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Offloading, first part: what stops an offload before anything is written, and a verified snapshot pinned in the
/// mirror with a verified copy in the second backup, resumed or abandoned safely after an interruption. restic runs
/// against repositories in temporary folders only. Invented data only.
@Suite(.serialized) struct BackupOffloadPinTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    static let hasRestic = Restic.locate() != nil

    /// A flag a test flips while a Backup's closures read it.
    final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var on: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    struct Env {
        let base: URL
        let support: URL
        let folder: URL
        var primary: URL { base.appendingPathComponent("icloud/Sprava Backup") }
        var second: URL { base.appendingPathComponent("external/Sprava Second") }
    }

    /// An adopted binder, managed by device "dev", holding one invented letter.
    func env() throws -> Env {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-offload-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("correspondence/notary"), withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: folder.appendingPathComponent("correspondence/notary/letter.pdf"))
        return Env(base: base, support: base.appendingPathComponent("support"), folder: folder)
    }

    /// A Backup with both repositories set up; the mirror counts as uploaded unless `waiting` is on.
    func configured(_ e: Env, waiting: Switch? = nil, second: Bool = true) throws -> Backup {
        let b = Backup(support: e.support, key: "TEST-KEY-AAAAA-BBBBB",
                       uploadCheck: { _ in waiting?.on == true ? .waiting(2) : .uploaded }, secondLocationCheck: { _ in true })
        try b.setUp(primary: e.primary, iCloudKeychain: false)
        if second { try b.setSecond(e.second) }
        return b
    }

    func pinned(_ b: Backup, _ repository: URL, _ id: String) throws -> [String] {
        try b.engine(repository.path).snapshots(tag: "binder:\(id)").filter { $0.tags.contains("offloaded") }.map(\.id)
    }

    // MARK: - What stops an offload before anything is written

    @Test(.enabled(if: hasRestic)) func anOffloadNeedsTheSecondBackupAndThisMacsBinder() throws {
        let e = try env()
        let b = try configured(e, second: false)
        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        try b.setSecond(e.second)
        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "another-mac", confirmOpenItems: true, now: now) }
        #expect(try b.state().offloads.isEmpty)
    }

    @Test(.enabled(if: hasRestic)) func openItemsNeedConfirmationAndWaitingFilesStopIt() throws {
        let e = try env()
        let b = try configured(e)
        #expect(throws: Backup.NeedsConfirmation.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: false, now: now) }
        // A file waiting in intake/, or one in outgoing/, stops it; a monitor's settings in intake/mail do not.
        try FileManager.default.createDirectory(at: e.folder.appendingPathComponent("intake/mail"), withIntermediateDirectories: true)
        try Data("invented".utf8).write(to: e.folder.appendingPathComponent("intake/mail/.env"))
        try Data("x".utf8).write(to: e.folder.appendingPathComponent("intake/scan.pdf"))
        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        try FileManager.default.removeItem(at: e.folder.appendingPathComponent("intake/scan.pdf"))
        try FileManager.default.createDirectory(at: e.folder.appendingPathComponent("outgoing"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: e.folder.appendingPathComponent("outgoing/letter.pdf"))
        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        // A card that cannot be read may be one waiting.
        try FileManager.default.removeItem(at: e.folder.appendingPathComponent("outgoing/letter.pdf"))
        try FileManager.default.createDirectory(at: e.folder.appendingPathComponent(".sprava/proposals"), withIntermediateDirectories: true)
        try Data("{ invented, not a card".utf8).write(to: e.folder.appendingPathComponent(".sprava/proposals/invented.json"))
        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(try b.state().offloads.isEmpty)
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
    }

    // MARK: - Pinned and copied

    @Test(.enabled(if: hasRestic)) func aVerifiedSnapshotIsPinnedInBothBackups() throws {
        let e = try env()
        let b = try configured(e)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) == .copied)
        let id = try Backup.backupID(e.folder)
        let job = try #require(try b.state().offloads[id])
        #expect(job.stage == "copied" && job.repository == e.primary.standardizedFileURL.path)
        #expect(try pinned(b, e.primary, id) == [try #require(job.snapshot)])
        #expect(try pinned(b, e.second, id) == [try #require(job.secondSnapshot)])
        // The person's confirmation of the open items is in the binder's history, once.
        let log = Teka.read(e.folder).catalog?["processing_log"]?.arrayValue ?? []
        #expect(log.filter { $0["action"]?.stringValue == "offloaded" }.count == 1)
        // The folder is still here: it leaves in the next step.
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.pendingOffloads().map(\.stage) == ["copied"])
    }

    @Test(.enabled(if: hasRestic)) func anOffloadWaitsForICloudThenCopies() throws {
        let e = try env()
        let waiting = Switch(true)
        let b = try configured(e, waiting: waiting)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) == .waitingForICloud(2))
        let id = try Backup.backupID(e.folder)
        #expect(try b.state().offloads[id]?.stage == "waiting_for_upload")
        #expect(try pinned(b, e.second, id).isEmpty)
        waiting.on = false
        #expect(try b.continueOffloads(now: now)[id].map { try $0.get() } == .copied)
    }

    @Test(.enabled(if: hasRestic)) func aBinderChangedWhileWaitingIsAbandonedAndUnpinned() throws {
        let e = try env()
        let waiting = Switch(true)
        let b = try configured(e, waiting: waiting)
        _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        let id = try Backup.backupID(e.folder)
        try Data("invented later page".utf8).write(to: e.folder.appendingPathComponent("correspondence/notary/second.pdf"))
        waiting.on = false
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now) }
        #expect(try b.state().offloads[id] == nil)
        #expect(try pinned(b, e.primary, id).isEmpty)
        // Offloading again backs up the binder as it is now.
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) == .copied)
        #expect(try pinned(b, e.primary, id).count == 1)
    }

    // MARK: - Interruptions

    /// Copies the support folder and both repositories when `step` is reached, as a crash there would leave them.
    final class Image: @unchecked Sendable {
        let dirs: [URL]
        let store: URL
        let step: String
        private let lock = NSLock()
        private(set) var taken = false
        init(_ dirs: [URL], at step: String) {
            self.dirs = dirs
            self.step = step
            store = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-offload-image-\(UUID().uuidString)")
        }
        func take(_ reached: String) {
            lock.lock(); defer { lock.unlock() }
            guard reached == step, !taken else { return }
            for (i, dir) in dirs.enumerated() where FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: dir, to: store.appendingPathComponent("\(i)"))
            }
            taken = true
        }
        func restore() throws {
            for (i, dir) in dirs.enumerated() {
                try? FileManager.default.removeItem(at: dir)
                let from = store.appendingPathComponent("\(i)")
                if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: dir) }
            }
        }
    }

    @Test(.enabled(if: hasRestic), arguments: ["offload.claimed", "offload.written", "offload.snapshotted", "offload.verified",
                                               "offload.copied"])
    func anInterruptedOffloadResumesWithOnePinInEachBackup(step: String) throws {
        let e = try env()
        var b = try configured(e)
        let image = Image([e.support, e.primary, e.second], at: step)
        b.atStep = { image.take($0) }
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) == .copied)
        #expect(image.taken)
        // As if Sprava had stopped there: the disk as it was, then the offload again.
        try image.restore()
        b.atStep = nil
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) == .copied)
        let id = try Backup.backupID(e.folder)
        let job = try #require(try b.state().offloads[id])
        #expect(try pinned(b, e.primary, id) == [try #require(job.snapshot)])
        #expect(try pinned(b, e.second, id) == [try #require(job.secondSnapshot)])
    }

    @Test(.enabled(if: hasRestic), arguments: ["offload.written", "offload.snapshotted", "offload.verified", "offload.copying"])
    func aQueuedContinuationResumesAnInterruptedOffload(step: String) throws {
        let e = try env()
        var b = try configured(e)
        let image = Image([e.support, e.primary, e.second], at: step)
        b.atStep = { image.take($0) }
        _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        try image.restore()
        b.atStep = nil
        let id = try Backup.backupID(e.folder)
        #expect(try b.continueOffloads(now: now)[id].map { try $0.get() } == .copied)
        let job = try #require(try b.state().offloads[id])
        #expect(try pinned(b, e.primary, id) == [try #require(job.snapshot)])
        #expect(try pinned(b, e.second, id) == [try #require(job.secondSnapshot)])
    }

    @Test(.enabled(if: hasRestic)) func aCopyThatLandedBeforeItsIDWasSavedIsUnpinnedWhenAbandoned() throws {
        let e = try env()
        var b = try configured(e)
        let image = Image([e.support, e.primary, e.second], at: "offload.copying")
        b.atStep = { image.take($0) }
        _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        try image.restore()
        b.atStep = nil
        let id = try Backup.backupID(e.folder)
        // The copy landed, and Sprava stopped before saving its id; then the binder changed.
        let job = try #require(try b.state().offloads[id])
        try b.engine(e.second.path).copy(try #require(job.snapshot), from: b.engine(e.primary.path))
        #expect(try pinned(b, e.second, id).count == 1)
        try Data("invented later page".utf8).write(to: e.folder.appendingPathComponent("correspondence/notary/second.pdf"))
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now) }
        #expect(try pinned(b, e.primary, id).isEmpty && pinned(b, e.second, id).isEmpty)
        #expect(try b.state().offloads[id] == nil)
    }

    @Test(.enabled(if: hasRestic)) func aMirrorChangedDuringTheWaitHasItsPinReleased() throws {
        let e = try env()
        let waiting = Switch(true)
        let b = try configured(e, waiting: waiting)
        _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        let id = try Backup.backupID(e.folder)
        #expect(try pinned(b, e.primary, id).count == 1)
        waiting.on = false
        try b.setUp(primary: e.base.appendingPathComponent("icloud/Another Mirror"), iCloudKeychain: false)
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now) }
        #expect(try pinned(b, e.primary, id).isEmpty)
        #expect(try b.state().offloads[id] == nil)
    }

    @Test(.enabled(if: hasRestic)) func aBinderMovedWhileItsOffloadWaitedIsBackedUpAndOffloadedAgain() throws {
        let e = try env()
        let waiting = Switch(true)
        let b = try configured(e, waiting: waiting)
        _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        let id = try Backup.backupID(e.folder)
        // Moved into another folder, under its own name.
        let parent = e.base.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let moved = parent.appendingPathComponent(e.folder.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: e.folder, to: moved)
        // Backups go on at the new place.
        _ = try b.backUp(moved, now: now)
        // The waiting offload is abandoned, with its pin released; offloading again starts from the new place.
        waiting.on = false
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now) }
        #expect(try pinned(b, e.primary, id).isEmpty)
        #expect(try b.offload(moved, deviceID: "dev", confirmOpenItems: true, now: now) == .copied)
    }

    @Test(.enabled(if: hasRestic)) func anOffloadResumesThroughALinkToTheSameFolder() throws {
        let e = try env()
        let waiting = Switch(true)
        let b = try configured(e, waiting: waiting)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) == .waitingForICloud(2))
        let alias = e.base.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: e.folder.deletingLastPathComponent())
        waiting.on = false
        let through = alias.appendingPathComponent(e.folder.lastPathComponent, isDirectory: true)
        #expect(try b.offload(through, deviceID: "dev", confirmOpenItems: true, now: now) == .copied)
        #expect(try pinned(b, e.primary, Backup.backupID(e.folder)).count == 1)
    }

    @Test(.enabled(if: hasRestic)) func exemptIntakeNamesCountOnlyWithTheirOwnTypeAndCardsOnlyWhenDone() throws {
        let e = try env()
        let b = try configured(e)
        // A file named _converted is not the converted-text folder: it waits.
        try FileManager.default.createDirectory(at: e.folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        try Data("invented".utf8).write(to: e.folder.appendingPathComponent("intake/_converted"))
        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        try FileManager.default.removeItem(at: e.folder.appendingPathComponent("intake/_converted"))
        // A superseded card is done (binder-v0 §6.5); one in a state Sprava does not know may be waiting.
        let replaced = Proposal.make(title: "Invented replaced card", actor: JSONObject([(key: "kind", value: .str("user"))]), ops: [], now: now)
        try ProposalStore.save(replaced, in: e.folder)
        let replacedFile = e.folder.appendingPathComponent(".sprava/proposals/\(replaced.id).json")
        try Data(try String(contentsOf: replacedFile, encoding: .utf8)
            .replacingOccurrences(of: "\"proposed\"", with: "\"superseded\"").utf8).write(to: replacedFile)
        #expect(try Backup.refuseNotReady(e.folder, Teka.read(e.folder)).count >= 0)
        let card = Proposal.make(title: "Invented card", actor: JSONObject([(key: "kind", value: .str("user"))]), ops: [], now: now)
        try ProposalStore.save(card, in: e.folder)
        let file = e.folder.appendingPathComponent(".sprava/proposals/\(card.id).json")
        let edited = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "\"proposed\"", with: "\"invented-state\"")
        try Data(edited.utf8).write(to: file)
        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(try b.state().offloads.isEmpty)
    }

    @Test(.enabled(if: hasRestic)) func aChangeWhileWaitingForICloudStartsOverWithoutWaiting() throws {
        let e = try env()
        let waiting = Switch(true)
        let b = try configured(e, waiting: waiting)
        _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        let id = try Backup.backupID(e.folder)
        try Data("invented later page".utf8).write(to: e.folder.appendingPathComponent("correspondence/notary/second.pdf"))
        // iCloud still has not uploaded, yet the obsolete snapshot is not waited on: the offload is abandoned.
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now) }
        #expect(try b.state().offloads[id] == nil && pinned(b, e.primary, id).isEmpty)
    }

    @Test func aSecondBackupInACloudServiceFolderIsACloudProviderLocation() {
        let home = URL(fileURLWithPath: "/Users/invented-person", isDirectory: true)
        #expect(Backup.isCloudProviderLocation(home.appendingPathComponent("Library/CloudStorage/Invented-Drive/Sprava"), home: home))
        #expect(!Backup.isCloudProviderLocation(URL(fileURLWithPath: "/Volumes/Invented Disk/Sprava"), home: home))
    }

    @Test func anOpenItemSwappedForAnotherNeedsConfirming() throws {
        func item(_ id: String) throws -> Item {
            Item(raw: try JSONParser.parse(Data(#"{"id":"\#(id)","title":"Invented \#(id)","status":"open"}"#.utf8)).value, index: 0)
        }
        var job = Backup.InProgress(path: "/invented/binder", stage: "copied")
        job.openItemsConfirmed = 1
        job.confirmedItems = ["a-1"]
        // The same number of open items, but a different one: it was never confirmed.
        job.confirmedItems = [Backup.confirmationKey(try item("a-1"))]
        #expect(Backup.unconfirmed([try item("a-2")], job).map(\.idText) == ["a-2"])
        #expect(Backup.unconfirmed([try item("a-1")], job).isEmpty)
        // A number and the same digits as text are two ids.
        let number = Item(raw: try JSONParser.parse(Data(#"{"id":7,"title":"Invented","status":"open"}"#.utf8)).value, index: 0)
        job.confirmedItems = [Backup.confirmationKey(number)]
        #expect(Backup.unconfirmed([try item("7")], job).count == 1)
    }

    @Test(.enabled(if: hasRestic)) func aSecondBackupMadeAgainEmptyAtItsPathGetsTheCopyAgain() throws {
        let e = try env()
        let b = try configured(e)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) == .copied)
        let id = try Backup.backupID(e.folder)
        // The second backup's disk is replaced: an empty repository at the same path.
        try FileManager.default.removeItem(at: e.second)
        try b.setSecond(e.second)
        #expect(try pinned(b, e.second, id).isEmpty)
        #expect(try b.continueOffload(id, now: now) == .copied)
        #expect(try pinned(b, e.second, id) == [try #require(b.state().offloads[id]?.secondSnapshot)])
    }

    @Test(.enabled(if: hasRestic)) func aMirrorMadeAgainEmptyAfterTheSnapshotStartsTheOffloadOver() throws {
        let e = try env()
        var b = try configured(e)
        let id = try Backup.backupID(e.folder)
        let image = Image([e.support, e.primary, e.second], at: "offload.snapshotted")
        b.atStep = { image.take($0) }
        _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        try image.restore()
        b.atStep = nil
        // The mirror is made again empty at its own path: the recorded snapshot is gone.
        try FileManager.default.removeItem(at: e.primary)
        try b.setUp(primary: e.primary, iCloudKeychain: false)
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now) }
        #expect(try b.state().offloads[id] == nil)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) == .copied)
    }
}
