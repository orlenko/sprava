import BinderFormat
import BinderStore
import Capture
import CaptureTestSupport
import Foundation
import Hub
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions for the Services layer on the reviewed lower layers: what the runtime, the CLI and the commands
/// report when Capture, the hub lane or the binder rules changed under them. Invented data only.
@Suite(.serialized) struct LowerLayerAdaptationTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    // MARK: - The capture job reports a state file it could not write

    @Test func aCaptureStateThatCouldNotBeSavedFailsTheJob() {
        #expect(CaptureJob.outcome(unreadable: nil, unsaved: nil, refusedFolders: 0) == .ok)
        #expect(CaptureJob.outcome(unreadable: nil, unsaved: "state.json", refusedFolders: 0)
                == .error(code: "capture_state_unwritable", culprit: "state.json"))
        // A state that cannot be read is said first: nothing was swept at all.
        #expect(CaptureJob.outcome(unreadable: "intake.json", unsaved: "state.json", refusedFolders: 0)
                == .error(code: "capture_state_unreadable", culprit: "intake.json"))
        #expect(CaptureJob.outcome(unreadable: nil, unsaved: nil, refusedFolders: 2) == .error(code: "capture_folder_refused", culprit: "2 folder(s)"))
        #expect(CaptureJob.outcome(unreadable: nil, unsaved: "state.json", refusedFolders: 2)
                == .error(code: "capture_state_unwritable", culprit: "state.json"))
    }

    @Test func aRealSweepThatCouldNotSaveItsStateFailsTheJob() throws {
        let capture = CaptureTests()
        let s = try capture.setup()
        try capture.note(s, "Invented errand")
        // Sprava's capture state folder cannot be written: the sweep stops and says which file it could not save.
        let stateDir = s.inbox.stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDir.path) }
        let r = s.inbox.sweep(binders: capture.rows(s), commands: s.commands, now: now)
        #expect(r.unsaved != nil)
        #expect(CaptureJob.outcome(r) == .error(code: "capture_state_unwritable", culprit: r.unsaved))
    }

    // MARK: - A note whose event file is in place is saved, even when its publish threw

    struct Flushless: Error, CustomStringConvertible { var description: String { "flush event folder failed" } }

    func producer() throws -> CaptureProducer {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-adapt-\(UUID().uuidString)")
        let root = base.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CaptureProducer(root: root, deviceID: "0f0e0d0c-0b0a-4908-8706-050403020100", support: base.appendingPathComponent("support"))
    }

    @Test func aNoteIsPublishedOnce() throws {
        let p = try producer()
        let note = try p.prepareNote("Call the invented notary", startedAt: now, savedAt: now, locale: "en-CA")
        #expect(NoteSave.publish(note, with: p) == .saved(id: note.id))
        #expect(FileManager.default.fileExists(atPath: p.folder.appendingPathComponent("\(note.id).json").path))
        // Publishing the same note again is refused, never a second file.
        guard case .savedNotConfirmed(let id, _) = NoteSave.publish(note, with: p) else {
            Issue.record("a second publish of a saved note must not read as not saved"); return
        }
        #expect(id == note.id)
        let events = try FileManager.default.contentsOfDirectory(atPath: p.folder.path).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        #expect(events == ["\(note.id).json"])
    }

    @Test func aThrowAfterTheEventIsInPlaceIsSavedNotConfirmed() throws {
        let p = try producer()
        let note = try p.prepareNote("Pay the invented plumber", startedAt: now, savedAt: now, locale: "en-CA")
        // Nothing written: not saved.
        #expect(NoteSave.after(Flushless(), id: note.id, producer: p) == .notSaved(reason: "flush event folder failed"))
        // The event file is there (its folder flush failed afterwards): saved, not confirmed.
        try note.bytes.write(to: p.folder.appendingPathComponent("\(note.id).json"))
        #expect(NoteSave.after(Flushless(), id: note.id, producer: p)
                == .savedNotConfirmed(id: note.id, reason: "flush event folder failed"))
    }

    @Test func aLinkUnderTheEventsNameIsNotASavedNote() throws {
        let p = try producer()
        let note = try p.prepareNote("Invented reminder", startedAt: now, savedAt: now, locale: "en-CA")
        let elsewhere = p.root.appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: p.folder.appendingPathComponent("\(note.id).json"), withDestinationURL: elsewhere)
        #expect(NoteSave.after(Flushless(), id: note.id, producer: p) == .notSaved(reason: "flush event folder failed"))
    }

    // MARK: - Filing an Inbox card into a binder that needs attention says so

    @Test func filingIntoABinderWhoseWritesAreBlockedPassesTheReasonThrough() throws {
        let capture = CaptureTests()
        let s = try capture.setup()
        try capture.note(s, "Collect the invented keys")
        _ = s.inbox.sweep(binders: capture.rows(s), commands: s.commands, now: now)
        let card = try #require(s.inbox.unfiled().first?.id)
        // An interrupted expunge blocks every write until it is repeated (binder-v0 §6.11).
        try Data().write(to: s.folder.appendingPathComponent(".sprava/expunge-pending"))
        #expect(Teka.read(s.folder).writesBlocked)
        let r = try call(s.commands, [("command", .str("file_card")), ("card", .string(card)), ("binder", .string(s.folder.path))])
        #expect(r["ok"] == .bool(false))
        #expect(r["error"] == .str("this binder needs attention; repair it first"), "\(r)")
        // The card stays in the Inbox.
        #expect(s.inbox.unfiled().contains { $0.id == card })
    }

    // MARK: - A stamped binder without a valid disclosure leaves the hub

    @Test func aStampedBinderWithoutADisclosureHasItsSliceWithdrawn() throws {
        let ops = BugbotOpsTests()
        let (folder, spool) = try ops.readyBinder(ops.commands())
        let slice = ops.sliceURL(spool, "rental-elm-street")
        guard case .published? = HubLane.sync(folder, root: spool, now: now).published else { Issue.record("not published"); return }
        #expect(FileManager.default.fileExists(atPath: slice.path))
        try ops.outsideEdit(folder) { c in
            var meta = c["meta"]?.objectValue ?? JSONObject()
            meta.remove("disclosure")
            c.set("meta", .object(meta))
        }
        #expect(Teka.read(folder).federationBlocked)
        let synced = HubLane.sync(folder, root: spool, now: now)
        #expect(synced.published == .removed, "\(String(describing: synced.published))")
        #expect(!FileManager.default.fileExists(atPath: slice.path))
        // Nothing of it is left to withdraw: later runs publish nothing and say why.
        #expect(HubLane.sync(folder, root: spool, now: now).published == .notPublished("the binder needs attention"))
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }
}
