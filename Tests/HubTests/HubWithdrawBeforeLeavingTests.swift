import BinderFormat
import BinderStore
import Darwin
import Foundation
@testable import Hub
import SpravaKit
import Testing

/// Taking a binder's slice off the hub before the binder leaves this Mac (an offload). Binders and spools live in
/// temporary folders only. Every value is invented.
@Suite struct HubWithdrawBeforeLeavingTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    /// An adopted binder `tax` with one open item, and a spool with an inbox; published once unless `publish` is false.
    func adopted(publish: Bool = true, formerName: String? = nil) throws -> (folder: URL, spool: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-hub-leaving-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("tax", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let former = formerName.map { #","former_names":[{"name":"\#($0)","until":"2099-01-01"}]"# } ?? ""
        let text = #"{"meta":{"schema_version":2,"name":"tax"\#(former)},"documents":[],"open_items":[{"id":"a-1","title":"Invented task","status":"open","priority":"normal","due":"2026-11-01","tags":["invented-tag"],"waiting_on":"Invented Party","link":"docs/invented-file.pdf"}],"processing_log":[]}"#
        try Data(text.utf8).write(to: folder.appendingPathComponent("catalog.json"))
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let spool = root.appendingPathComponent("spool", isDirectory: true)
        for sub in ["inbox", "outbox"] {
            try FileManager.default.createDirectory(at: spool.appendingPathComponent(sub), withIntermediateDirectories: true)
            chmod(spool.appendingPathComponent(sub).path, 0o700)
        }
        chmod(spool.path, 0o700)
        if publish {
            guard case .published = try HubLane.publish(folder, root: spool, now: now) else { throw TekaStore.Refused(reason: "publish failed") }
        }
        return (folder, spool)
    }

    func slice(_ spool: URL, _ name: String = "tax") throws -> URL {
        try HubLane.spoolFile(spool.appendingPathComponent("inbox"), name, ".agenda.json")
    }

    @Test func aPublishedSliceIsTakenOff() throws {
        let (folder, spool) = try adopted()
        #expect(FileManager.default.fileExists(atPath: try slice(spool).path))
        #expect(try TekaStore(folder: folder).withLock { try HubLane.withdrawBeforeLeaving(folder, root: spool, nameCollides: false) })
        #expect(!FileManager.default.fileExists(atPath: try slice(spool).path))
        #expect(HubLane.loadCursors(folder).sliceName == nil)
    }

    @Test func noSpoolOrNoInboxMeansNoSlice() throws {
        let (folder, spool) = try adopted(publish: false)
        let missing = spool.deletingLastPathComponent().appendingPathComponent("no-spool")
        #expect(try HubLane.withdrawBeforeLeaving(folder, root: missing, nameCollides: false))
        try FileManager.default.removeItem(at: spool.appendingPathComponent("inbox"))
        #expect(try HubLane.withdrawBeforeLeaving(folder, root: spool, nameCollides: false))
    }

    @Test func aSpoolThatOthersCanWriteIsRefused() throws {
        let (folder, spool) = try adopted()
        chmod(spool.appendingPathComponent("inbox").path, 0o777)
        defer { chmod(spool.appendingPathComponent("inbox").path, 0o700) }
        #expect(throws: TekaStore.Refused.self) { _ = try HubLane.withdrawBeforeLeaving(folder, root: spool, nameCollides: false) }
        #expect(FileManager.default.fileExists(atPath: try slice(spool).path))
    }

    @Test func underACollidingNameOnlyTheRecordedSliceGoes() throws {
        let (folder, spool) = try adopted()
        // Another program has since written its own slice under the shared name: it is not this binder's.
        let other = Data(#"{"teka":"tax","items":[{"id":"x","title":"Another binder's invented task"}]}"#.utf8)
        try other.write(to: try slice(spool))
        #expect(try HubLane.withdrawBeforeLeaving(folder, root: spool, nameCollides: true))
        #expect(try Data(contentsOf: try slice(spool)) == other)
    }

    @Test func aBinderWithNoSafelyIdentifiedSliceMustNotLeave() throws {
        let (folder, spool) = try adopted(publish: false)
        // Colliding, and nothing recorded: no slice can be named safely.
        #expect(try !HubLane.withdrawBeforeLeaving(folder, root: spool, nameCollides: true))
    }

    @Test func underACollidingNameAnUnreadableEntryIsLeft() throws {
        for replacement in ["malformed", "link"] {
            let (folder, spool) = try adopted()
            let target = try slice(spool)
            try FileManager.default.removeItem(at: target)
            if replacement == "link" {
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "elsewhere.json")
            } else {
                try Data("{ invented, not json".utf8).write(to: target)
            }
            // Left in place, and the withdrawal fails with the record kept: it is not known to be gone.
            #expect(throws: TekaStore.Refused.self) { _ = try HubLane.withdrawBeforeLeaving(folder, root: spool, nameCollides: true) }
            var info = stat()
            #expect(lstat(target.path, &info) == 0)
            #expect(HubLane.loadCursors(folder).sliceName != nil)
        }
    }

    @Test func aSliceLargerThanTheDefaultReadLimitIsStillRecognised() throws {
        let (_, spool) = try adopted()
        let target = try slice(spool)
        // An invented slice of 17 MiB, above SafeFile's default limit, is read back to be checked.
        let big = #"{"teka":"tax","items":[{"id":"x","title":""# + String(repeating: "a", count: 17 << 20) + #""}]}"#
        try Data(big.utf8).write(to: target)
        #expect(HubLane.sliceOnSpool(at: target) != nil)
    }

    @Test func underACollidingNameASliceWithAnotherStampIsLeft() throws {
        let (folder, spool) = try adopted()
        let target = try slice(spool)
        // The other binder's slice projects the same items, so it has the same hash, under a later stamp.
        var slice = try JSONParser.parse(try Data(contentsOf: target)).value.objectValue!
        slice.set("generated", .str("2099-01-01T00:00:00Z"))
        let other = Data(JSONWriter.pretty(.object(slice)).utf8)
        try other.write(to: target)
        #expect(try HubLane.withdrawBeforeLeaving(folder, root: spool, nameCollides: true))
        #expect(try Data(contentsOf: target) == other)
    }

    @Test func aSliceUnderAFormerNameGoesEvenWithoutCursors() throws {
        let (folder, spool) = try adopted(formerName: "old-tax")
        let former = try slice(spool, "old-tax")
        try Data(#"{"teka":"old-tax","items":[]}"#.utf8).write(to: former)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".sprava/cursors.json"))
        #expect(try HubLane.withdrawBeforeLeaving(folder, root: spool, nameCollides: false, now: now))
        #expect(!FileManager.default.fileExists(atPath: former.path))
        #expect(!FileManager.default.fileExists(atPath: try slice(spool).path))
    }
}
