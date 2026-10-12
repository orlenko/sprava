import BinderFormat
import BinderStore
import Darwin
import Foundation
@testable import Hub
import SpravaKit
import Testing

@Suite struct HubPrivacyInspectionTests {
    let fixture = HubWithdrawBeforeLeavingTests()

    func catalog(_ folder: URL, edit: (inout JSONObject) -> Void) throws {
        let file = folder.appendingPathComponent("catalog.json")
        var value = try #require(try JSONParser.parse(Data(contentsOf: file)).value.objectValue)
        edit(&value)
        try Data(JSONWriter.pretty(.object(value)).utf8).write(to: file)
    }

    @Test func unchangedPublicationIsSafeAndInspectionWritesNothing() throws {
        let (folder, spool) = try fixture.adopted()
        let files = [folder.appendingPathComponent("catalog.json"), folder.appendingPathComponent(".sprava/ops.ndjson"),
                     folder.appendingPathComponent(".sprava/cursors.json"), try fixture.slice(spool)]
        let before = try files.map { try Data(contentsOf: $0) }
        let report = HubLane.inspectPrivacy(Teka.read(folder), root: spool, now: fixture.now)
        #expect(report.privacy?.disclosure == "full")
        #expect(report.issues.isEmpty)
        #expect(try files.map { try Data(contentsOf: $0) } == before)
    }

    @Test func itemRedactionAndRemovalAreCheckedEvenWithTheRecordedHash() throws {
        for remove in [false, true] {
            let (folder, spool) = try fixture.adopted()
            try catalog(folder) { value in
                if remove { value.set("open_items", .array([])); return }
                var item = value["open_items"]!.arrayValue![0].objectValue!
                item.set("redact", .bool(true))
                value.set("open_items", .array([.object(item)]))
            }
            let report = HubLane.inspectPrivacy(Teka.read(folder), root: spool, now: fixture.now)
            #expect(report.privacy?.disclosure == "full")
            #expect(report.issues.contains(.showsMore))
            #expect(!report.issues.contains(.otherPublisher))
        }
    }

    @Test func formerNamesWithoutCursorsAndRecordedNamesAreChecked() throws {
        for recorded in [false, true] {
            let (folder, spool) = try fixture.adopted(formerName: recorded ? nil : "old-tax")
            let source = try fixture.slice(spool)
            let target = try fixture.slice(spool, "old-tax")
            try FileManager.default.moveItem(at: source, to: target)
            if recorded {
                var c = try HubLane.readCursors(folder)
                c.sliceName = "old-tax"
                try HubLane.saveCursors(c, folder)
            } else {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(".sprava/cursors.json"))
            }
            try catalog(folder) { value in
                var meta = value["meta"]!.objectValue!
                meta.set("disclosure", .str("none"))
                value.set("meta", .object(meta))
            }
            #expect(HubLane.inspectPrivacy(Teka.read(folder), root: spool, now: fixture.now).issues.contains(.privateSlice("none")))
            #expect(FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func invalidHistoryCannotConfirmAWiderDisclosure() throws {
        let (folder, spool) = try fixture.adopted()
        try TekaStore(folder: folder).apply([.init(op: "set_disclosure", args: .init([(key: "disclosure", value: .str("none"))]),
                                                  actor: .init([(key: "kind", value: .str("user"))]))], now: fixture.now)
        try catalog(folder) { value in
            var meta = value["meta"]!.objectValue!
            meta.set("disclosure", .str("full"))
            value.set("meta", .object(meta))
        }
        let file = folder.appendingPathComponent(".sprava/ops.ndjson")
        let before = try Data(contentsOf: file)
        var log = try TekaStore(folder: folder).readOpLog().ops
        let hash = try #require(log.last?["after_hash"])
        log.append(JSONObject([(key: "id", value: .str("invented-invalid-op")), (key: "op", value: .str("set_disclosure")),
                              (key: "actor", value: .obj([("kind", .str("user"))])),
                              (key: "args", value: .obj([("disclosure", .str("full"))])),
                              (key: "before_hash", value: hash), (key: "after_hash", value: .str("invalid"))]))
        let damaged = Data(log.map { JSONWriter.compact(.object($0)) + "\n" }.joined().utf8)
        try damaged.write(to: file)
        let report = HubLane.inspectPrivacy(Teka.read(folder), root: spool, now: fixture.now)
        #expect(report.privacy == nil)
        #expect(report.issues.contains(.unknownPrivacy))
        #expect(try Data(contentsOf: file) == damaged)
        try before.write(to: file)
        #expect(HubLane.inspectPrivacy(Teka.read(folder), root: spool).privacy?.disclosure == "none")
    }

    @Test func itemPrivacyWideningsRemainVisibleAtFullDisclosure() throws {
        let (folder, spool) = try fixture.adopted()
        let id = JSONValue.str("a-1")
        try TekaStore(folder: folder).apply([.init(op: "update_item", args: .init([
            (key: "id", value: id), (key: "set", value: .obj([("redact", .bool(true)), ("kind", .str("payment")),
                                                            ("slice_title", .str("Invented approved label"))]))]),
            actor: .init([(key: "kind", value: .str("user"))]))], now: fixture.now)
        try catalog(folder) { value in
            var item = value["open_items"]!.arrayValue![0].objectValue!
            item.remove("redact")
            item.remove("kind")
            item.set("slice_title", .str("Invented outside label"))
            value.set("open_items", .array([.object(item)]))
        }
        let privacy = try #require(HubLane.inspectPrivacy(Teka.read(folder), root: spool).privacy)
        #expect(privacy.disclosure == "full")
        #expect(privacy.lifted == [id])
        #expect(privacy.retitled.count == 1)
        #expect(privacy.unkinded == [id])
    }

    @Test func unsafeSliceEntriesAreReportedWithoutFollowingOrWaiting() throws {
        for kind in ["fifo", "link", "malformed", "large"] {
            let (folder, spool) = try fixture.adopted()
            let file = try fixture.slice(spool)
            try FileManager.default.removeItem(at: file)
            switch kind {
            case "fifo": #expect(mkfifo(file.path, 0o600) == 0)
            case "link": try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "missing.json")
            case "large":
                #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: UInt64(9 << 20))
                try handle.close()
            default: try Data("{ invalid".utf8).write(to: file)
            }
            #expect(HubLane.inspectPrivacy(Teka.read(folder), root: spool, now: fixture.now).issues.contains(.unavailable))
        }
    }

    @Test func linkedInboxAndCursorDirectoryAreRefused() throws {
        for entry in ["inbox", ".sprava"] {
            let (folder, spool) = try fixture.adopted()
            let original = (entry == "inbox" ? spool : folder).appendingPathComponent(entry)
            let moved = original.deletingLastPathComponent().appendingPathComponent("invented-moved")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
            #expect(HubLane.inspectPrivacy(Teka.read(folder), root: spool, now: fixture.now).issues.contains(.unavailable))
        }
    }

    @Test func missingSpoolDoesNotCreateItAndHistoryBudgetRemainsUnknown() throws {
        let (folder, spool) = try fixture.adopted()
        let missing = spool.appendingPathComponent("not-configured")
        #expect(HubLane.inspectPrivacy(Teka.read(folder), root: missing).issues.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let history = folder.appendingPathComponent(".sprava/ops.ndjson")
        let handle = try FileHandle(forWritingTo: history)
        try handle.truncate(atOffset: UInt64(2 << 20))
        try handle.close()
        #expect(HubLane.inspectPrivacy(Teka.read(folder), root: spool).privacy == nil)
    }
}
