import Combine
import Foundation
import SpravaKit
import SwiftUI

@MainActor final class PersonPageEditor: ObservableObject, DraftOwner {
    struct Page: Equatable {
        let folder: URL
        let document: JSONValue
        let path: String
        let revision: String
        let number: Int
        var fields: [(String, JSONValue)] { [("document_id", document), ("path", .str(path)), ("revision", .str(revision)), ("page", .int(number))] }
    }
    private let client: RuntimeClient
    @Published private(set) var page: Page?
    @Published private(set) var loaded = false
    @Published private(set) var saving = false
    @Published private(set) var original: String?
    @Published var text = ""
    @Published private(set) var message: String?
    init(client: RuntimeClient = RuntimeClient()) { self.client = client }
    var draftState: DraftState { .init(hasChanges: loaded && text != (original ?? ""), saving: saving) }

    func open(_ page: Page) async {
        guard !saving, !draftState.hasChanges, self.page != page || !loaded else { return }
        self.page = page; loaded = false; original = nil; text = ""; message = nil
        do {
            let reply = try await client.command("page_reading", binder: page.folder, page.fields)
            guard self.page == page else { return }
            guard let prior = reply["text"], prior == .null || prior.stringValue != nil else { throw CocoaError(.fileReadCorruptFile) }
            original = prior.stringValue; text = original ?? ""; loaded = true
        } catch { if self.page == page { message = "Your saved reading could not be opened. \(error)" } }
    }

    func save() async {
        guard let page, loaded, !saving else { return }
        saving = true; message = nil
        defer { saving = false }
        do {
            _ = try await client.command("save_page_reading", binder: page.folder, page.fields + [("text", .str(text)), ("expected", original.map(JSONValue.str) ?? .null)])
            original = text
        } catch { message = "Your reading is still here. \(error)" }
    }

    func close() {
        guard !saving else { return }
        page = nil; loaded = false; original = nil; text = ""; message = nil
    }
}

struct PersonPageEditorView: View {
    @ObservedObject var editor: PersonPageEditor
    let page: PersonPageEditor.Page
    var body: some View {
        VStack(alignment: .leading) {
            if editor.page == page, editor.loaded {
                Text("Your reading").font(.headline)
                TextEditor(text: $editor.text).frame(minHeight: 60, maxHeight: 120).disabled(editor.saving)
                HStack {
                    let empty = editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button(empty ? "Mark as Read Without Text" : "Save My Reading") { Task { await editor.save() } }
                        .disabled(editor.saving || editor.original == editor.text || editor.text.utf8.count > 16_384)
                    if editor.original == editor.text {
                        Text(empty ? "Marked as read. This page has no searchable text." : "Saved as your reading.").foregroundStyle(.secondary)
                    }
                }
            }
            if let message = editor.message { Text(verbatim: message).foregroundStyle(.orange) }
        }.task(id: page) { await editor.open(page) }
    }
}
