import BinderFormat
import BinderStore
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// New binders from a template through the command table (mvp.md feature 6). Invented data only.
@Suite(.serialized) struct CreateBinderTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func setup() throws -> (Commands, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-template-\(UUID().uuidString)")
        let parent = base.appendingPathComponent("binders")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (Commands(support: base.appendingPathComponent("support"), deviceID: "dev"), parent)
    }

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    @Test func aNewTaxYearBinderIsReadyAndItsChecklistIsOneCard() throws {
        let (c, parent) = try setup()
        let r = try call(c, [("command", .str("create_binder")), ("parent", .string(parent.path)), ("name", .str("tax-2026")), ("year", .int(2026))])
        #expect(r["ok"] == .bool(true), "\(r)")
        let folder = URL(fileURLWithPath: try #require(r["binder"]?.stringValue))
        let teka = Teka.read(folder)
        #expect(teka.state == .ready, "\(teka.reasons)")
        #expect(teka.level == .tekaV0 && teka.isAdopted && teka.findings.isEmpty)
        #expect(teka.catalog?["meta"]?["disclosure"] == .str("none"))
        #expect(Owner.device(of: folder) == "dev")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("receipts").path))
        // The checklist card is verified and approves into undated items with minted ids.
        let listed = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])
        let card = try #require(listed["proposals"]?.arrayValue?.first)
        #expect(card["verified"] == .bool(true))
        let approved = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        #expect(approved["ok"] == .bool(true), "\(approved)")
        let items = Teka.read(folder).items
        #expect(items.count == BinderTemplate.taxYear.checklist.count)
        #expect(items.allSatisfy { $0.hasNoDeadline && $0.idText.hasPrefix("tax-2026-2026-") })
        #expect(Teka.read(folder).state == .ready)
        _ = try Replay.run(try TekaStore(folder: folder).readOpLog().ops)
        // On the shelf, off the filing list, with the template's description ready.
        #expect(ShelfStore(supportDirectory: c.support).pickedFolders().map(\.lastPathComponent) == ["tax-2026"])
        let settings = try call(c, [("command", .str("binder_settings")), ("binder", .string(folder.path))])
        #expect(settings["filing"] == .bool(false))
        #expect(settings["description"]?.stringValue?.hasPrefix("Tax year 2026") == true)
    }

    @Test func aBlankBinderIsReadyWithNoCard() throws {
        let (c, parent) = try setup()
        let r = try call(c, [("command", .str("create_binder")), ("parent", .string(parent.path)), ("name", .str("kitchen-reno")),
                             ("template", .str("blank"))])
        #expect(r["ok"] == .bool(true), "\(r)")
        #expect(r["proposal"] == .null)
        let folder = URL(fileURLWithPath: try #require(r["binder"]?.stringValue))
        #expect(Teka.read(folder).state == .ready)
        #expect(ProposalStore.list(in: folder).isEmpty)
    }

    /// Any name the person types becomes a valid, free one; nothing is refused after the dialogs for its name.
    @Test func typedNamesDuplicatesAndExistingFoldersBecomeValidFreeNames() throws {
        let (c, parent) = try setup()
        func create(_ name: String, in folder: URL, year: Int = 2026) throws -> String? {
            let r = try call(c, [("command", .str("create_binder")), ("parent", .string(folder.path)), ("name", .string(name)),
                                 ("template", .str("tax-year")), ("year", .int(year))])
            #expect(r["ok"] == .bool(true), "\(r)")
            return r["binder"]?.stringValue.map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        #expect(try create("MapleStreet", in: parent) == "maplestreet")
        #expect(try create("Maple Street", in: parent) == "maple-street")
        #expect(try create("Caf\u{E9} \u{DC}n\u{EF}code", in: parent) == "cafe-unicode")
        #expect(try create("  --Tax 2026!! ", in: parent) == "tax-2026")
        #expect(try create(String(repeating: "Maple elm ", count: 10), in: parent)?.count == 64)
        // Nothing left: the template's suggestion, which is taken, so the next number.
        #expect(try create("\u{65E5}\u{672C}", in: parent) == "tax-2026-2")
        // The same name again, even in another folder, and a folder already holding the name.
        let other = parent.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(try create("tax-2026", in: other) == "tax-2026-3")
        try FileManager.default.createDirectory(at: other.appendingPathComponent("tax-2027"), withIntermediateDirectories: true)
        #expect(try create("TAX-2027", in: other, year: 2027) == "tax-2027-2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.appendingPathComponent("tax-2027").path).isEmpty)
        for name in try FileManager.default.contentsOfDirectory(atPath: parent.path) {
            #expect(Teka.read(parent.appendingPathComponent(name)).catalog?["meta"]?["name"] == .string(name))
        }
    }

    @Test func anEmptyFolderBecomesTheBinderRenamedToItsName() throws {
        let (c, parent) = try setup()
        let picked = parent.appendingPathComponent("Garden Shed")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        try Data().write(to: picked.appendingPathComponent(".DS_Store"))
        let r = try call(c, [("command", .str("create_binder")), ("folder", .string(picked.path)), ("name", .str("garden-shed")),
                             ("template", .str("blank"))])
        #expect(r["ok"] == .bool(true), "\(r)")
        let folder = URL(fileURLWithPath: try #require(r["binder"]?.stringValue))
        #expect(folder.lastPathComponent == "garden-shed" && folder.deletingLastPathComponent().path == parent.path)
        #expect(!FileManager.default.fileExists(atPath: picked.path))
        #expect(Teka.read(folder).state == .ready)
        #expect(ShelfStore(supportDirectory: c.support).pickedFolders().map(\.lastPathComponent) == ["garden-shed"])
    }

    @Test func anEmptyFolderWhoseNameDiffersOnlyInCaseIsRenamed() throws {
        let (c, parent) = try setup()
        let picked = parent.appendingPathComponent("Shed")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let r = try call(c, [("command", .str("create_binder")), ("folder", .string(picked.path)), ("name", .str("shed")),
                             ("template", .str("blank"))])
        #expect(r["ok"] == .bool(true), "\(r)")
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(names == ["shed"])
        #expect(Teka.read(parent.appendingPathComponent("shed")).state == .ready)
    }

    @Test func aFolderThatIsNotEmptyIsLeftAsItIsAndATakenNewNameGetsANumber() throws {
        let (c, parent) = try setup()
        let full = parent.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
        try Data("invented".utf8).write(to: full.appendingPathComponent("a.txt"))
        #expect(try call(c, [("command", .str("create_binder")), ("folder", .string(full.path)), ("name", .str("notes"))])["ok"] == .bool(false))
        #expect(try FileManager.default.contentsOfDirectory(atPath: full.path) == ["a.txt"])
        let empty = parent.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("taken"), withIntermediateDirectories: true)
        let r = try call(c, [("command", .str("create_binder")), ("folder", .string(empty.path)), ("name", .str("taken"))])
        #expect(r["ok"] == .bool(true), "\(r)")
        #expect(r["binder"]?.stringValue.map { URL(fileURLWithPath: $0).lastPathComponent } == "taken-2")
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent("taken").path).isEmpty)
    }
}
