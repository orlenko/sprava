import BinderFormat
@testable import Clerk
import ClerkTestSupport
import Extract
import Foundation
import SpravaKit
import Testing

/// The person's instructions choose where an intake document is filed, within what code checks (decisions.md D43;
/// docs/binder-instructions.md §4). Invented binders, rules and text only.
@Suite struct FilingGuidanceTests {
    let now = Date(timeIntervalSince1970: 1_791_460_800)
    let rules = "Utility bills go in bills, in a folder for each provider.\nInsurance letters go in insurance/policies.\n"
    let text = "Northwind Power\nYour October bill is $84.20. Please pay it by November 15."

    final class Engine: DocumentEngine, @unchecked Sendable {
        let name = "Claude"
        let takesGuidance: Bool
        var reply: JSONValue
        var instructions: [String] = []
        var guided: [Bool] = []
        init(_ reply: JSONValue, takesGuidance: Bool = true) { self.reply = reply; self.takesGuidance = takesGuidance }
        func answer(instructions: String, prompt: String) async throws -> JSONValue { try await answer(instructions: instructions, prompt: prompt, guided: false) }
        func answer(instructions: String, prompt: String, guided: Bool) async throws -> JSONValue {
            self.instructions.append(instructions)
            self.guided.append(guided)
            return reply
        }
    }

    static func answer(folder: String, fileName: String = "") -> JSONValue {
        .obj([("class", .str("action")), ("title", .str("Northwind Power")), ("date_text", .str("")),
              ("summary", .str("A power bill asks for $84.20 by November 15.")), ("reply_needed", .bool(false)),
              ("items", .array([])), ("folder", .string(folder)), ("file_name", .string(fileName))])
    }

    var guidance: FilingGuidance { FilingGuidance(text: rules, cut: false, folders: ["documents", "bills", "insurance"]) }

    func read(_ engine: Engine?, guidance: FilingGuidance?, model: ScriptedModel = ScriptedModel(extractions: [])) async -> DocumentReading {
        model.document = .obj([("class", .str("action")), ("title", .str("Northwind Power")), ("date_text", .str("")),
                               ("summary", .str("A power bill.")), ("reply_needed", .bool(false))])
        let reading = IntakeReading(kind: "pdf", textFrom: "parsed", text: text, channel: "download")
        return await Clerk(model: model).readDocument(reading, name: "scan-0042.pdf", binder: nil, locale: "en",
                                                      engine: engine, guidance: guidance, now: now)
    }

    @Test func theRuleChangesTheFolderAndTheName() async {
        let engine = Engine(Self.answer(folder: "bills/Northwind Power", fileName: "Northwind Power 2026-10"))
        let doc = await read(engine, guidance: guidance)
        #expect(doc.folder == "bills/Northwind Power")
        #expect(doc.fileName == "Northwind Power 2026-10.pdf")
        #expect(doc.json["folder_from"] == .str("instructions") && doc.json["name_from"] == .str("instructions"))
        #expect(engine.guided == [true])
        #expect(engine.instructions[0].contains("PERSON'S INSTRUCTIONS BEGIN\n" + rules))
        #expect(engine.instructions[0].contains("The binder's folders: documents, bills, insurance"))
        // Without instructions the same answer chooses nothing.
        let plain = await read(Engine(Self.answer(folder: "bills/Northwind Power")), guidance: nil)
        #expect(plain.folder == nil && plain.fileName == nil)
    }

    @Test func aFolderNeitherOwnNorWrittenIsRefused() {
        let g = guidance
        #expect(g.checkedFolder("insurance/policies") == "insurance/policies")   // written out whole
        #expect(g.checkedFolder("/Bills/") == "bills")                            // the binder's own spelling
        #expect(g.checkedFolder("insurance/policies/2026") == "insurance/policies/2026")
        #expect(g.checkedFolder("taxes") == nil)                                  // neither
        #expect(g.checkedFolder("bills/a/b") == nil)                              // two new segments
        #expect(g.checkedFolder("../outside") == nil)
        #expect(g.checkedFolder("intake/held") == nil)
        #expect(g.checkedFolder(".hidden") == nil)
        #expect(g.checkedFolder("a/b/c/d/e") == nil)
        // A path is written out only whole: "policies" alone is not in the text as a path of its own.
        #expect(FilingGuidance.writesOut(rules, "insurance/policies"))
        #expect(!FilingGuidance.writesOut(rules, "policies"))
        #expect(FilingGuidance.writesOut("File it in receipts.", "receipts"))
    }

    @Test func aNameThatWouldHideTheFileIsRefused() {
        #expect(FilingGuidance.checkedName("credentials 2026", original: "letter.pdf") == nil)
        #expect(FilingGuidance.checkedName("credentials", original: "letter.json") == nil)
        #expect(FilingGuidance.checkedName("token-notice", original: "notice.json") == nil)
        #expect(FilingGuidance.checkedName("statement.key", original: "statement") == nil)
        #expect(FilingGuidance.checkedName("Hydro 2026-10.pdf", original: "scan.pdf") == "Hydro 2026-10.pdf")
        #expect(FilingGuidance.checkedName("a/b", original: "scan.pdf") == "a_b.pdf")
        #expect(FilingGuidance.checkedName("AGENTS", original: "notes.md") == "_AGENTS.md")
        #expect(FilingGuidance.checkedName("  ", original: "scan.pdf") == nil)
    }

    @Test func anEngineThatMayNotHaveThemGetsNoneAndTheClerkChooses() async {
        let engine = Engine(Self.answer(folder: "insurance"), takesGuidance: false)
        let model = ScriptedModel(extractions: [])
        model.filing = "bills"
        let doc = await read(engine, guidance: guidance, model: model)
        #expect(engine.guided == [false])
        #expect(!engine.instructions[0].contains("PERSON'S INSTRUCTIONS"))
        #expect(doc.folder == "bills" && doc.fileName == nil)
    }

    @Test func theOnDeviceClerkChoosesOnlyFromTheList() async {
        let model = ScriptedModel(extractions: [])
        model.filing = "bills"
        let doc = await read(nil, guidance: guidance, model: model)
        #expect(doc.folder == "bills")
        model.filing = "elsewhere"
        let none = await read(nil, guidance: guidance, model: model)
        #expect(none.folder == nil)
    }

    @Test func instructionsTooLongForTheClerkAreSaidOnTheCard() async {
        let long = FilingGuidance(text: String(repeating: "Bills go in bills. ", count: 900), cut: false, folders: ["bills"])
        let model = ScriptedModel(extractions: [])
        model.filing = "bills"
        let doc = await read(nil, guidance: long, model: model)
        #expect(doc.folder == nil)
        #expect(doc.instructionsNote == "Your instructions are too long for the on-device reader.")
    }

    @Test func onlyAcceptedInstructionsAreFollowed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-guidance-\(UUID().uuidString)/household")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bills/Northwind Power"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".sprava"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        #expect(FilingGuidance.of(folder, catalog: nil) == (nil, nil))
        try Data(rules.utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        let unaccepted = FilingGuidance.of(folder, catalog: nil)
        #expect(unaccepted.guidance == nil && unaccepted.note == "Your instructions changed outside Sprava and were not used.")
        try Data(#"{"accepted": "\#(BinderInstructions.digest(rules))"}"#.utf8).write(to: folder.appendingPathComponent(".sprava/instructions.json"))
        let accepted = FilingGuidance.of(folder, catalog: nil)
        #expect(accepted.note == nil)
        #expect(accepted.guidance?.text == rules.trimmingCharacters(in: .whitespacesAndNewlines))
        // The binder's own folders: on disk, without intake or hidden ones.
        #expect(accepted.guidance?.folders == ["bills", "bills/Northwind Power"])
    }
}
