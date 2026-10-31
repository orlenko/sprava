import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import Testing

@Suite struct TemplateLibraryTests {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-template-library-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func manifest(key: String = "violin-workshop", folders: [String] = ["inventory", "repairs", "sales"]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "key": key, "title": "Instrument workshop",
            "summary": "Purchase, repairs and resale", "name": "", "folders": folders,
            "checklist": ["Record purchase evidence", "Record the observed condition"]])
    }

    @Test func anUnrecognizedProjectCanBeAddedAsFilesAndCreatesItsOwnGuide() throws {
        let base = try root(), library = TemplateLibrary(support: base.appendingPathComponent("support"))
        _ = try library.read()
        let custom = library.folder.appendingPathComponent("violin-workshop")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: false)
        try manifest().write(to: custom.appendingPathComponent("template.json"))
        let guide = "Distinguish observed condition from a seller's claims. Cite purchase and repair records.\n"
        try Data(guide.utf8).write(to: custom.appendingPathComponent("PROJECT.md"))
        let chosen = try #require(library.read().first { $0.key == "violin-workshop" })
        #expect(chosen.folders == ["inventory", "repairs", "sales"] && chosen.guide == guide)
        let created = try BinderCreator.create(parent: base, name: "instrument-project", template: chosen,
            deviceID: "invented-device", knownNames: [], year: 2026, today: CalendarDate(year: 2026, month: 10, day: 31)!)
        #expect(try String(contentsOf: created.folder.appendingPathComponent("PROJECT.md"), encoding: .utf8) == guide)
        #expect(Teka.read(created.folder).state == .ready)
        #expect(Teka.read(created.folder).catalog?["meta"]?["template"]?["key"] == .str("violin-workshop"))
        #expect(FileManager.default.fileExists(atPath: created.folder.appendingPathComponent("repairs").path))
        try Data("A revised guide for future binders.\n".utf8).write(to: custom.appendingPathComponent("PROJECT.md"))
        #expect(try library.read().first { $0.key == "violin-workshop" }?.guide != chosen.guide)
        #expect(try String(contentsOf: created.folder.appendingPathComponent("PROJECT.md"), encoding: .utf8) == guide)
    }

    @Test func editsAndDeletionsAreNotResetFromBundledPresets() throws {
        let library = TemplateLibrary(support: try root())
        let original = try library.read()
        let first = try #require(original.first)
        let guide = library.folder.appendingPathComponent(first.key + "/PROJECT.md")
        try Data("My own project conventions.\n".utf8).write(to: guide)
        #expect(try library.read().first { $0.key == first.key }?.guide == "My own project conventions.\n")
        for template in original { try FileManager.default.removeItem(at: library.folder.appendingPathComponent(template.key)) }
        #expect(try library.read().isEmpty)
    }

    @Test(arguments: [["../escape"], ["/absolute"], [".claude/hooks"], ["PROJECT.md"], ["folder//child"], ["catalog.json/child"]])
    func unsafeScaffoldingIsRejectedBeforeAnyBinderIsCreated(folders: [String]) throws {
        #expect(throws: BinderTemplate.Invalid.self) { try BinderTemplate(data: manifest(folders: folders), guide: "") }
    }

    @Test func aLinkedGuideCannotReadAnOutsideFile() throws {
        let base = try root(), library = TemplateLibrary(support: base.appendingPathComponent("support"))
        let first = try #require(library.read().first)
        let guide = library.folder.appendingPathComponent(first.key + "/PROJECT.md")
        let outside = base.appendingPathComponent("outside.txt")
        try Data("invented outside canary".utf8).write(to: outside)
        try FileManager.default.removeItem(at: guide)
        try FileManager.default.createSymbolicLink(at: guide, withDestinationURL: outside)
        #expect(throws: BinderTemplate.Invalid.self) { try library.read() }
        #expect(try library.prepareFolder() == library.folder)
    }
}
