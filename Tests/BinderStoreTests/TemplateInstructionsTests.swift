import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import Testing

/// A template may carry a starting text for a new binder's instructions (decisions.md D43; docs/binder-instructions.md
/// §5). Invented templates and text only.
@Suite struct TemplateInstructionsTests {
    let today = CalendarDate(year: 2026, month: 10, day: 31)!
    let rules = "This binder holds an invented workshop's records.\n- Repair invoices go in repairs.\n"

    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-template-instructions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func manifest() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "key": "violin-workshop", "title": "Instrument workshop",
            "summary": "Purchase, repairs and resale", "name": "", "folders": ["repairs"], "checklist": [String]()])
    }

    @Test func aTemplatesInstructionsBecomeTheBindersOwnAndAreFollowed() throws {
        let base = try root(), library = TemplateLibrary(support: base.appendingPathComponent("support"))
        _ = try library.read()
        let custom = library.folder.appendingPathComponent("violin-workshop")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: false)
        try manifest().write(to: custom.appendingPathComponent("template.json"))
        try Data("An invented guide.\n".utf8).write(to: custom.appendingPathComponent("PROJECT.md"))
        try Data(rules.utf8).write(to: custom.appendingPathComponent("instructions.md"))
        let chosen = try #require(library.read().first { $0.key == "violin-workshop" })
        #expect(chosen.instructions == rules)
        // The instructions are part of what the preview showed: the same template through its json, the same fingerprint.
        let again = try BinderTemplate(json: chosen.json)
        #expect(again.instructions == rules && again.fingerprint == chosen.fingerprint)
        #expect(try BinderTemplate(data: manifest(), guide: "An invented guide.\n").fingerprint != chosen.fingerprint)

        let created = try BinderCreator.create(parent: base, name: "workshop", template: chosen, deviceID: "invented-device",
                                               knownNames: [], year: 2026, today: today)
        #expect(try String(contentsOf: created.folder.appendingPathComponent("AGENTS.md"), encoding: .utf8) == rules)
        guard case .success(let found) = BinderInstructions.read(created.folder) else { Issue.record("unreadable"); return }
        #expect(found.text == rules && found.isAccepted && !found.canUndo)
        // Editing the template changes only binders made later.
        try Data("Other invented rules.\n".utf8).write(to: custom.appendingPathComponent("instructions.md"))
        #expect(try String(contentsOf: created.folder.appendingPathComponent("AGENTS.md"), encoding: .utf8) == rules)
    }

    @Test func aTemplateWithoutThemWritesNoAgentsFile() throws {
        let base = try root()
        let plain = try BinderTemplate(data: manifest(), guide: "An invented guide.\n")
        #expect(plain.instructions == nil && plain.json["instructions"] == nil)
        let created = try BinderCreator.create(parent: base, name: "plain", template: plain, deviceID: "invented-device",
                                               knownNames: [], year: 2026, today: today)
        #expect(!FileManager.default.fileExists(atPath: created.folder.appendingPathComponent("AGENTS.md").path))
    }

    @Test func instructionsOverTheBoundOrWithSpravasMarkersAreRefused() throws {
        let long = String(repeating: "x", count: BinderInstructions.maxCharacters + 1)
        let marked = "Rules.\n\(BinderInstructions.begin)\nSprava's.\n\(BinderInstructions.end)\n"
        for text in [long, marked] {
            #expect(throws: BinderTemplate.Invalid.self) { try BinderTemplate(data: manifest(), guide: "", instructions: text) }
        }
        #expect(throws: BinderTemplate.Invalid.self) {
            try BinderTemplate(json: .obj([("manifest", .string(String(decoding: try manifest(), as: UTF8.self))), ("guide", .str("")), ("instructions", .int(1))]))
        }
    }

    @Test func theShippedExamplesCarryShortInstructions() throws {
        for key in ["condo-board", "tax-year", "instrument-trading"] {
            let text = try #require(try TemplateLibrary.bundled(key).instructions)
            #expect(!text.isEmpty && text.count < 1_000)
            #expect(!text.lowercased().contains("lifeproj"))
        }
        #expect(try TemplateLibrary.bundled("blank").instructions == nil)
        // A new library is seeded with them.
        let library = TemplateLibrary(support: try root())
        #expect(try library.read().first { $0.key == "tax-year" }?.instructions == TemplateLibrary.bundled("tax-year").instructions)
    }
}
