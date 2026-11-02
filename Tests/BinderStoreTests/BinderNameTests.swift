import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import Testing

/// Whatever the person types as a new binder's name becomes a valid one (binder-v0 §3.1) instead of a refusal after the
/// dialogs. Invented data only.
@Suite struct BinderNameTests {
    let today = CalendarDate(year: 2026, month: 10, day: 7)!

    func parent() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let long = String(repeating: "Garden shed ", count: 9) + "plans"   // 113 characters

    @Test(arguments: [("MapleStreet", "maplestreet"), ("Maple Street", "maple-street"), ("Caf\u{E9} \u{DC}n\u{EF}code", "cafe-unicode"),
                      ("  --Tax 2026!! ", "tax-2026"), ("kitchen-reno", "kitchen-reno"), ("\u{65E5}\u{672C}", "new-binder"),
                      ("", "new-binder"), ("?!", "new-binder")])
    func aTypedNameBecomesAValidBinderThatIsCreated(typed: String, expected: String) throws {
        let name = BinderCreator.name(for: typed, template: try TemplateLibrary.bundled("blank"), year: 2026)
        #expect(name == expected)
        let parent = try parent()
        let created = try BinderCreator.create(parent: parent, name: name, template: try TemplateLibrary.bundled("blank"), deviceID: "dev", knownNames: [],
                                               year: 2026, today: today)
        #expect(created.folder.lastPathComponent == expected)
        #expect(Teka.read(created.folder).catalog?["meta"]?["name"] == .string(expected))
    }

    @Test func aLongNameIsCutToSixtyFourCharactersWithNoTrailingHyphen() throws {
        let name = BinderCreator.name(for: Self.long, template: try TemplateLibrary.bundled("blank"), year: 2026)
        #expect(name.count <= 64 && !name.hasSuffix("-") && name.hasPrefix("garden-shed-garden-shed"))
        #expect(name.wholeMatch(of: /[a-z0-9][a-z0-9-]*/) != nil)
        let created = try BinderCreator.create(parent: try parent(), name: name, template: try TemplateLibrary.bundled("blank"), deviceID: "dev", knownNames: [],
                                               year: 2026, today: today)
        #expect(created.folder.lastPathComponent == name)
    }

    @Test func aNameWithNothingLeftFallsBackToTheFolderThenTheTemplate() throws {
        let folder = URL(fileURLWithPath: "/invented/Garden Shed", isDirectory: true)
        #expect(BinderCreator.name(for: "\u{65E5}\u{672C}", template: try TemplateLibrary.bundled("tax-year"), year: 2026, existing: folder) == "garden-shed")
        let other = URL(fileURLWithPath: "/invented/\u{65E5}\u{672C}", isDirectory: true)
        #expect(BinderCreator.name(for: "!!", template: try TemplateLibrary.bundled("tax-year"), year: 2026, existing: other) == "tax-2026")
        #expect(BinderCreator.name(for: "", template: try TemplateLibrary.bundled("tax-year"), year: 2026) == "tax-2026")
    }

    @Test func aTakenNameGetsTheNextFreeNumber() throws {
        let parent = try parent()
        #expect(BinderCreator.freeName("tax-2026", parent: parent, knownNames: []) == "tax-2026")
        // Another binder on the shelf has it, in any case.
        #expect(BinderCreator.freeName("tax-2026", parent: parent, knownNames: ["Tax-2026"]) == "tax-2026-2")
        // A folder of that name is already in the parent, and so is the first number.
        for taken in ["tax-2026", "tax-2026-2"] {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent(taken), withIntermediateDirectories: true)
        }
        let free = BinderCreator.freeName("tax-2026", parent: parent, knownNames: [])
        #expect(free == "tax-2026-3")
        _ = try BinderCreator.create(parent: parent, name: free, template: try TemplateLibrary.bundled("blank"), deviceID: "dev", knownNames: [], year: 2026, today: today)
        // A long name leaves room for the number.
        let long = String(repeating: "a", count: 64)
        #expect(BinderCreator.freeName(long, parent: parent, knownNames: [long]) == String(repeating: "a", count: 62) + "-2")
    }

    @Test func theEmptyFolderThatBecomesTheBinderDoesNotTakeItsOwnName() throws {
        let parent = try parent()
        let picked = parent.appendingPathComponent("shed")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        #expect(BinderCreator.freeName("shed", parent: parent, knownNames: [], existing: picked) == "shed")
        #expect(BinderCreator.freeName("shed", parent: parent, knownNames: []) == "shed-2")
    }

    /// `create` stays the final guard: a name not in the shape is refused when passed to it directly.
    @Test(arguments: ["Tax 2026", "-tax", "tax/2026", "", "TAX-2026", String(repeating: "a", count: 65)])
    func createStillRefusesAnInvalidName(name: String) throws {
        let parent = try parent()
        #expect(throws: TekaStore.Refused.self) {
            try BinderCreator.create(parent: parent, name: name, template: try TemplateLibrary.bundled("blank"), deviceID: "dev", knownNames: [], year: 2026, today: today)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
}
