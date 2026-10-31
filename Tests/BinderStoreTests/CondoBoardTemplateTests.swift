import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import Testing

/// The condo-board starter (mvp.md feature 6): an adopted binder at disclosure `none` with its folders and an undated
/// checklist as one card, and the other templates still usable. Invented temporary folders only.
@Suite struct CondoBoardTemplateTests {
    let today = CalendarDate(year: 2026, month: 10, day: 7)!

    func parent() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-template-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func create(_ template: BinderTemplate, name: String) throws -> BinderCreator.Created {
        try BinderCreator.create(parent: try parent(), name: name, template: template, deviceID: "dev", knownNames: [],
                                 year: 2026, today: today)
    }

    @Test func aCondoBoardBinderIsAdoptedPrivateAndFoldered() throws {
        let created = try create(try TemplateLibrary.bundled("condo-board"), name: BinderCreator.name(for: "", template: try TemplateLibrary.bundled("condo-board"), year: 2026))
        #expect(created.folder.lastPathComponent == "condo-board")
        let teka = Teka.read(created.folder)
        #expect(teka.isAdopted)
        #expect(teka.catalog?["meta"]?["disclosure"]?.stringValue == "none")
        for sub in ["governing", "meetings", "finances", "maintenance", "correspondence", "intake"] {
            var isFolder: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: created.folder.appendingPathComponent(sub).path, isDirectory: &isFolder)
                    && isFolder.boolValue, "\(sub)")
        }
        #expect(!(try TemplateLibrary.bundled("condo-board")).description(2026).isEmpty)
    }

    /// The checklist waits as one card for the person, with every item undated: no due, follow-up or expected date.
    @Test func itsChecklistIsOneUndatedCard() throws {
        let created = try create(try TemplateLibrary.bundled("condo-board"), name: "condo-board")
        let id = try #require(created.checklistCard)
        let card = try ProposalStore.load(id, in: created.folder, expectedDigest: nil)
        #expect(card.state == "proposed")
        let items = card.ops.compactMap { $0["args"]?["item"]?.objectValue }
        #expect(card.ops.allSatisfy { $0["op"]?.stringValue == "add_item" })
        #expect(items.compactMap { $0["title"]?.stringValue } == (try TemplateLibrary.bundled("condo-board")).checklist)
        for item in items {
            #expect(item["no_deadline"] == .bool(true))
            for field in ["due", "follow_up_at", "expected_by", "recurrence"] { #expect(item[field] == nil, "\(field)") }
        }
        // Nothing is applied before the person approves the card.
        #expect(Teka.read(created.folder).catalog?["open_items"]?.arrayValue?.isEmpty == true)
    }

    @Test func theOtherTemplatesStillWork() throws {
        #expect(try TemplateLibrary(support: parent()).read().map(\.key).sorted() == ["blank", "condo-board", "instrument-trading", "tax-year"])
        #expect(try create(try TemplateLibrary.bundled("blank"), name: "new-binder").checklistCard == nil)
        let tax = try create(try TemplateLibrary.bundled("tax-year"), name: "tax-2026")
        let card = try ProposalStore.load(try #require(tax.checklistCard), in: tax.folder, expectedDigest: nil)
        #expect(card.ops.count == (try TemplateLibrary.bundled("tax-year")).checklist.count)
    }
}
