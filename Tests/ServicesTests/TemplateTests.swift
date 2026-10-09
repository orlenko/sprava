import BinderFormat
import BinderStore
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct TemplateTests {
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

    @Test func badNamesDuplicatesAndExistingFoldersAreRefused() throws {
        let (c, parent) = try setup()
        for name in ["Tax 2026", "-tax", "tax/2026", "", "TAX-2026"] {
            #expect(try call(c, [("command", .str("create_binder")), ("parent", .string(parent.path)), ("name", .string(name))])["ok"] == .bool(false))
        }
        #expect(try call(c, [("command", .str("create_binder")), ("parent", .string(parent.path)), ("name", .str("tax-2026"))])["ok"] == .bool(true))
        // The same name again, even in another folder.
        let other = parent.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(try call(c, [("command", .str("create_binder")), ("parent", .string(other.path)), ("name", .str("tax-2026"))])["ok"] == .bool(false))
        try FileManager.default.createDirectory(at: other.appendingPathComponent("tax-2027"), withIntermediateDirectories: true)
        #expect(try call(c, [("command", .str("create_binder")), ("parent", .string(other.path)), ("name", .str("tax-2027"))])["ok"] == .bool(false))
    }
}
