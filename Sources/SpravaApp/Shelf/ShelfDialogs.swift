import AppKit
import BinderStore

/// The Shelf's dialogs. The model asks through closures that default to these, so tests show no UI.
extension ShelfModel {
    /// The template and name, asked in one alert. For an empty folder the name starts from the folder's own, in the
    /// shape a new binder's name takes, and the folder is renamed to it when they differ. Any name is taken as typed;
    /// the model turns it into a valid one (`binderName`).
    static func binderAlert(empty: URL?, year: Int) -> (template: String, name: String)? {
        let alert = NSAlert()
        let shape = "The folder is named in lowercase with hyphens: Maple Street becomes maple-street. A template's checklist arrives as one card to approve."
        if let empty {
            alert.messageText = "Make \u{201C}\(empty.lastPathComponent)\u{201D} a new binder?"
            alert.informativeText = "The folder is empty. Pick a starting point and a name. \(shape)"
        } else {
            alert.messageText = "New binder"
            alert.informativeText = "Pick a starting point and a name. \(shape)"
        }
        let templates = BinderTemplate.all
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 260, height: 26))
        picker.addItems(withTitles: templates.map(\.title))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = empty.map { BinderCreator.name(for: $0.lastPathComponent, template: templates[0], year: year) }
            ?? templates[0].suggestedName(year)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
        box.addSubview(picker)
        box.addSubview(field)
        alert.accessoryView = box
        alert.addButton(withTitle: empty == nil ? "Choose Where…" : "Make Binder")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (templates[max(0, picker.indexOfSelectedItem)].key, field.stringValue)
    }

    /// The folder that will hold a new binder.
    static func parentPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Create Here"
        panel.message = "Choose the folder that will hold the new binder."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// The folders to add to the Shelf; empty when the person cancels.
    static func addPanel() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Shelf"
        panel.message = "Choose binder folders (each holds a catalog.json), or an empty folder to make a new binder in."
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
