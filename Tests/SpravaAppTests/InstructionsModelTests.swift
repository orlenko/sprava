import BinderFormat
import Foundation
@testable import SpravaApp
import SpravaKit
import Testing

/// The Instructions tab's model (docs/binder-instructions.md §3): what it sends, and that a reload never loses a draft.
/// Every text is invented.
@MainActor @Suite struct InstructionsModelTests {
    final class Binder: @unchecked Sendable {
        var instructions = BinderInstructions(exists: true, section: "", text: "Old rule.\n")
        var sent: [JSONValue] = []
        var fail = false
    }

    func model(_ binder: Binder) -> InstructionsModel {
        let client = RuntimeClient(answer: { text in
            let request = try JSONParser.parse(Data(text.utf8)).value
            binder.sent.append(request)
            if let saved = request["text"]?.stringValue {
                binder.instructions = BinderInstructions(exists: true, section: "", text: saved, accepted: BinderInstructions.digest(saved))
            }
            return #"{"ok":true,"digest":"x"}"#
        })
        return InstructionsModel(client: client, reader: { _ in (.success(binder.instructions), []) })
    }

    let folder = URL(fileURLWithPath: "/invented/household", isDirectory: true)

    @Test func aSaveSendsTheDigestItReadAndShowsTheSavedText() async throws {
        let binder = Binder()
        let model = model(binder)
        await model.load(folder)
        #expect(model.text == "Old rule.\n" && !model.edited)
        model.text = "Bills go in bills.\n"
        #expect(model.draftState.hasChanges)
        await model.save(folder)
        let request = try #require(binder.sent.first)
        #expect(request["command"] == .str("save_instructions"))
        #expect(request["expected"] == .string(BinderInstructions.digest("Old rule.\n")))
        #expect(request["text"] == .str("Bills go in bills.\n"))
        #expect(model.text == "Bills go in bills.\n" && !model.edited && model.found?.isAccepted == true)
    }

    @Test func aReloadKeepsADraft() async {
        let binder = Binder()
        let model = model(binder)
        await model.load(folder)
        model.text = "My draft.\n"
        binder.instructions = BinderInstructions(exists: true, section: "", text: "Changed elsewhere.\n")
        await model.load(folder)
        #expect(model.text == "My draft.\n")
        #expect(model.latest?.text == "Changed elsewhere.\n" && model.found?.text == "Old rule.\n")
    }

    @Test func aFailedReadKeepsTheDraftAndWhatItStartedFrom() async {
        let binder = Binder()
        let model = InstructionsModel(client: RuntimeClient(answer: { _ in #"{"ok":true}"# }),
                                      reader: { _ in (binder.fail ? .failure(.ambiguousMarkers) : .success(binder.instructions), []) })
        await model.load(folder)
        model.text = "My draft.\n"
        binder.fail = true
        await model.load(folder)
        #expect(model.problem == .ambiguousMarkers)
        #expect(model.text == "My draft.\n" && model.edited && model.draftState.hasChanges)
        #expect(model.found?.text == "Old rule.\n")
    }

    @Test func aChangeUnderADraftIsSaidAndRevertTakesIt() async {
        let binder = Binder()
        let model = model(binder)
        await model.load(folder)
        model.text = "My draft.\n"
        binder.instructions = BinderInstructions(exists: true, section: "", text: "Changed elsewhere.\n")
        await model.load(folder)
        #expect(model.changedUnderDraft)
        // The save still checks against what the draft started from, so the runtime refuses it.
        #expect(model.found?.digest == BinderInstructions.digest("Old rule.\n"))
        model.revert()
        #expect(model.text == "Changed elsewhere.\n" && !model.edited && !model.changedUnderDraft)
        model.text = "<!-- sprava:begin -->\nx\n<!-- sprava:end -->\n"
        #expect(model.holdsMarkers)
    }

    @Test func useThisTextConfirmsTheTextOnDisk() async throws {
        let binder = Binder()
        let model = model(binder)
        await model.load(folder)
        await model.save(folder, useThisText: true)
        #expect(try #require(binder.sent.first)["text"] == .str("Old rule.\n"))
    }

    @Test func copyInAppendsWithoutSaving() async {
        let binder = Binder()
        let model = model(binder)
        await model.load(folder)
        model.copyIn(.init(name: "CLAUDE.md", text: "File receipts in receipts.\n"))
        #expect(model.text == "Old rule.\n\nFile receipts in receipts.\n")
        #expect(binder.sent.isEmpty)
        model.text = "Run lifeproj publish last."
        #expect(model.namesLifeproj)
    }
}
