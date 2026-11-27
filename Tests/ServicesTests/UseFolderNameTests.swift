import BinderFormat
import BinderStore
import Foundation
import Hub
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// #689, second part: a binder whose folder was renamed or copied had no way to its stamp. The person's rename gives it
/// the folder's name and says what becomes of the old one.
@Suite struct UseFolderNameTests: BinderCommandFixture {
    /// An invented lifeproj binder whose catalog names it `house-sample`, in a folder of another name, adopted.
    private func adopted(_ c: Commands, folderName: String) throws -> URL {
        let folder = try makeTeka(fixture: "lifeproj-v2-fresh", folderName: folderName) { f in
            let catalog = """
            {"meta": {"schema_version": 2, "name": "house-sample"}, "documents": [], "processing_log": [],
             "open_items": [{"id": "house-sample-2026-001", "title": "Invented chore", "status": "open", "priority": "normal", "due": "2027-01-15"}]}
            """
            try Data(catalog.utf8).write(to: f.appendingPathComponent("catalog.json"))
        }
        let r = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
        #expect(r["ok"] == .bool(true), "\(r)")
        return folder
    }

    private func cards(_ c: Commands, _ folder: URL) throws -> [JSONValue] {
        (try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? [])
            .filter { $0["state"] == .str("proposed") }
    }

    private func rename(_ c: Commands, _ folder: URL, former: String?) throws -> JSONValue {
        try call(c, [("command", .str("use_folder_name")), ("binder", .string(folder.path))] + (former.map { [("former", .string($0))] } ?? []))
    }

    @Test func aCopyTakesItsFoldersNameAndNeverHoldsTheOldOne() throws {
        let c = commands()
        let folder = try adopted(c, folderName: "house-copy")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Teka.read(folder).nameDiffersFromFolder)
        // The differing name holds the stamp back.
        #expect(try cards(c, folder).contains { $0["title"] == .str("Stamp this binder as binder v0") } == false)

        let r = try rename(c, folder, former: "copy")
        #expect(r["ok"] == .bool(true) && r["stamp"]?.stringValue != nil, "\(r)")
        let meta = try #require(Teka.read(folder).catalog?["meta"])
        #expect(meta["name"] == .str("house-copy"))
        // The old name ended yesterday: this binder never drains, withdraws or blocks what belongs to the original.
        #expect(meta["former_names"] == .array([.obj([("name", .str("house-sample")), ("until", .string(today.adding(days: -1).description))])]))
        #expect(!Teka.read(folder).nameDiffersFromFolder)
        let op = try #require(try TekaStore(folder: folder).readOpLog().ops.last { $0["op"] == .str("rename_teka") })
        #expect(op["actor"]?["kind"] == .str("user") && op["id"] == r["op"])

        let stamp = try #require(try cards(c, folder).first { $0["title"] == .str("Stamp this binder as binder v0") })
        #expect(stamp["id"] == r["stamp"])
        let approved = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", stamp["id"]!), ("digest", stamp["digest"]!)])
        #expect(approved["ok"] == .bool(true), "\(approved)")
        #expect(Teka.read(folder).state == .ready, "\(Teka.read(folder).reasons)")
        // Nothing is left to rename.
        #expect(try rename(c, folder, former: "copy")["error"]?.stringValue?.contains("already is its folder's name") == true)
    }

    @Test func aRenamedBinderKeepsItsOldNameForThirtyDays() throws {
        let c = commands()
        let folder = try adopted(c, folderName: "house-renamed")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try rename(c, folder, former: "renamed")["ok"] == .bool(true))
        let meta = try #require(Teka.read(folder).catalog?["meta"])
        #expect(meta["name"] == .str("house-renamed"))
        #expect(meta["former_names"] == .array([.obj([("name", .str("house-sample")), ("until", .string(today.adding(days: 30).description))])]))
    }

    @Test func theRenameIsRefusedWithoutAnAnswerOrABinderItAppliesTo() throws {
        let c = commands()
        let folder = try adopted(c, folderName: "house-other")
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        // Whose the old name is must be said: there is no default.
        #expect(try rename(c, folder, former: nil)["error"]?.stringValue?.contains("renamed or copy") == true)
        #expect(try rename(c, folder, former: "whatever")["error"]?.stringValue?.contains("renamed or copy") == true)
        // Another Sprava's binder is read-only here.
        #expect(try rename(Commands(support: c.support, deviceID: "another-device"), folder, former: "copy")["error"]?.stringValue?
            .contains("read-only") == true)
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == before)

        // A binder not yet adopted is adopted first.
        let fresh = try makeTeka(fixture: "lifeproj-v2-fresh", folderName: "house-fresh") { f in
            try Data(#"{"meta": {"schema_version": 2, "name": "house-sample"}, "documents": [], "processing_log": [], "open_items": []}"#.utf8)
                .write(to: f.appendingPathComponent("catalog.json"))
        }
        defer { try? FileManager.default.removeItem(at: fresh) }
        #expect(try rename(c, fresh, former: "copy")["error"]?.stringValue?.contains("adopt this binder first") == true)
        #expect(!FileManager.default.fileExists(atPath: fresh.appendingPathComponent(".sprava").path))
    }

    // Review of #689: a copy of a binder that already shared under a name carries that binder's claims. Choosing
    // "copy" ended only the current name: the copy still drained an earlier name and could remove the original's slice.
    @Test func aBinderThatHoldsHubHistoryIsNotMadeACopy() throws {
        let c = commands()
        // It was renamed once, so it holds its first name for thirty days; then its folder is copied under a third name.
        let folder = try adopted(c, folderName: "house-renamed-once")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try rename(c, folder, former: "renamed")["ok"] == .bool(true))
        let copy = folder.deletingLastPathComponent().appendingPathComponent("house-copied-later")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: folder, to: copy)
        let before = try Data(contentsOf: copy.appendingPathComponent("catalog.json"))
        let refused = try rename(c, copy, former: "copy")
        #expect(refused["error"]?.stringValue?.contains("cannot yet make it an independent copy") == true, "\(refused)")
        #expect(try Data(contentsOf: copy.appendingPathComponent("catalog.json")) == before)

        // A binder whose cursors record a slice written from its folder is held the same way.
        let published = try adopted(c, folderName: "house-published")
        defer { try? FileManager.default.removeItem(at: published) }
        let cursors = #"{"sliceHash": "\#(String(repeating: "a", count: 64))", "sliceName": "house-sample", "published": {}, "closedOnce": [], "lastLogCount": 0}"#
        try Data(cursors.utf8).write(to: published.appendingPathComponent(".sprava/cursors.json"))
        #expect(HubLane.holdsHubHistory(Teka.read(published), today: today))
        #expect(try rename(c, published, former: "copy")["error"]?.stringValue?.contains("cannot yet make it an independent copy") == true)
        // Cursors that cannot be read count as holding.
        try Data("not json".utf8).write(to: published.appendingPathComponent(".sprava/cursors.json"))
        #expect(try rename(c, published, former: "copy")["ok"] == .bool(false))
        // The same binder under a new folder name is still renamed.
        try FileManager.default.removeItem(at: published.appendingPathComponent(".sprava/cursors.json"))
        try Data(cursors.utf8).write(to: published.appendingPathComponent(".sprava/cursors.json"))
        #expect(try rename(c, published, former: "renamed")["ok"] == .bool(true))

        // A former name past its date holds nothing.
        let expired = try adopted(c, folderName: "house-expired")
        defer { try? FileManager.default.removeItem(at: expired) }
        #expect(!HubLane.holdsHubHistory(Teka.read(expired), today: today))
        #expect(try rename(c, expired, former: "copy")["ok"] == .bool(true))
        #expect(!HubLane.holdsHubHistory(Teka.read(expired), today: today))
    }
}
