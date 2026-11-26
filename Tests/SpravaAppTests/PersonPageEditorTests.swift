import Foundation
import Testing
import SpravaKit
@testable import SpravaApp

@MainActor @Suite struct PersonPageEditorTests {
    @Test func aFailedSavePreservesTheTextAndTheExpectedOriginal() async {
        var sent: JSONValue?
        let client = RuntimeClient(answer: { raw in
            let request = try JSONParser.parse(raw).value
            if request["command"] == .str("page_reading") { return #"{"ok":true,"text":""}"# }
            sent = request
            throw CocoaError(.fileWriteNoPermission)
        })
        let editor = PersonPageEditor(client: client)
        let page = PersonPageEditor.Page(folder: URL(fileURLWithPath: "/invented"), document: .int(7), path: "garden.pdf", revision: String(repeating: "a", count: 64), number: 3)
        await editor.open(page)
        #expect(editor.original == "" && editor.loaded)
        editor.text = "Water the trays at dusk."
        await editor.save()
        #expect(sent?["document_id"] == .int(7) && sent?["page"] == .int(3) && sent?["expected"] == .str(""))
        #expect(editor.text == "Water the trays at dusk." && editor.draftState.hasChanges && !editor.saving)
    }
}
