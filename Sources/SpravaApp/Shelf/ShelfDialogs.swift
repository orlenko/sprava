import AppKit
import BinderStore

/// A new binder's template key, its name and its year, as typed in the alert.
typealias NewBinderAnswer = (template: String, name: String, year: String)

/// The Shelf's dialogs. The model asks through closures that default to these, so tests show no UI.
extension ShelfModel {
    /// The template, name and, for a tax year, the year, asked in one alert. `year` is the current year, the year field's
    /// first value. For an empty folder the name starts from the folder's own, in the shape a new binder's name takes,
    /// and the folder is renamed to it when they differ. The name follows the template and the year until the person
    /// types one of their own. Any name and year are returned as typed; the model checks the year (`projectYear`) and turns
    /// the name into a valid one (`binderName`).
    static func binderAlert(empty: URL?, year: Int, parent: URL, templates: [BinderTemplate]) -> NewBinderAnswer? {
        guard !templates.isEmpty else { return nil }
        let (alert, fields) = binderDialog(empty: empty, year: year, parent: parent, templates: templates)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        alert.window.makeFirstResponder(nil)
        return (fields.template.key, fields.name.stringValue, fields.year.stringValue)
    }

    /// Built separately so the confirmation and field validation can be checked without opening a modal.
    static func binderDialog(empty: URL?, year: Int, parent: URL, templates: [BinderTemplate]) -> (NSAlert, NewBinderFields) {
        let alert = NSAlert()
        let shape = "Review the folders, checklist and project guide below. This binder keeps its own copy."
        if let empty {
            alert.messageText = "Make \u{201C}\(empty.lastPathComponent)\u{201D} a new binder?"
            alert.informativeText = "The folder is empty. Pick a starting point and a name. \(shape)"
        } else {
            alert.messageText = "New binder"
            alert.informativeText = "\(shape)\n\nLocation: \(parent.path)\nChange this in Settings."
        }
        let create = alert.addButton(withTitle: "Create Binder")
        let fields = NewBinderFields(empty: empty, year: year, create: create, templates: templates)
        alert.accessoryView = fields.box
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = fields.name
        return (alert, fields)
    }

    /// A template's optional year: four digits, independent of the project category or current date.
    static func projectYear(_ typed: String) -> Int? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard text.count == 4, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), let year = Int(text),
              year >= 1000 else { return nil }
        return year
    }

    /// The current year in the Gregorian calendar, as `create_binder` counts it: the system calendar may be another one,
    /// such as the Japanese, whose year is the era's.
    static func currentYear(_ now: Date = Date()) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.component(.year, from: now)
    }

    /// The name the dialog suggests for a template and year.
    static func suggestedName(template: BinderTemplate, year: Int, empty: URL?) -> String {
        empty.map { BinderCreator.name(for: $0.lastPathComponent, template: template, year: year) } ?? template.suggestedName(year)
    }

    /// The name field after the template or year changed: the new suggestion while the field still holds the last one or
    /// nothing, else what the person typed.
    static func followSuggestion(name: String, last: String, next: String) -> String {
        name == last || name.trimmingCharacters(in: .whitespaces).isEmpty ? next : name
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

/// The new-binder alert's fields: the template picker, the year (shown for a tax year only) and the name, which follows
/// the other two until the person types their own.
@MainActor
final class NewBinderFields: NSObject, NSTextFieldDelegate {
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 270))
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 240, width: 360, height: 26))
    let yearLabel = NSTextField(labelWithString: "Year")
    let year = NSTextField(frame: NSRect(x: 96, y: 210, width: 70, height: 24))
    let name = NSTextField(frame: NSRect(x: 55, y: 180, width: 305, height: 24))
    let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 160))
    private let templates: [BinderTemplate]
    private let empty: URL?
    private let current: Int
    private var last: String
    private let create: NSButton

    var template: BinderTemplate { templates[max(0, picker.indexOfSelectedItem)] }

    init(empty: URL?, year current: Int, create: NSButton, templates: [BinderTemplate]) {
        precondition(!templates.isEmpty)
        self.empty = empty
        self.current = current
        self.create = create
        self.templates = templates
        last = ShelfModel.suggestedName(template: templates[0], year: current, empty: empty)
        super.init()
        picker.addItems(withTitles: templates.map(\.title))
        picker.target = self
        picker.action = #selector(templateChanged)
        yearLabel.frame = NSRect(x: 0, y: 213, width: 90, height: 18)
        year.stringValue = String(current)
        year.delegate = self
        name.stringValue = last
        name.placeholderString = "e.g. Garden Shed"
        name.delegate = self
        name.setAccessibilityLabel("Binder name")
        picker.setAccessibilityLabel("Starting point")
        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.frame = NSRect(x: 0, y: 183, width: 50, height: 18)
        for view in [picker, yearLabel, year, nameLabel, name] { box.addSubview(view) }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 165))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        preview.isEditable = false
        preview.isHorizontallyResizable = false
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.textContainerInset = NSSize(width: 6, height: 6)
        preview.font = .systemFont(ofSize: 12)
        preview.setAccessibilityLabel("Template contents")
        scroll.documentView = preview
        box.addSubview(scroll)
        showYear()
        validate()
    }

    @objc func templateChanged() {
        showYear()
        suggest()
        validate()
    }

    func controlTextDidChange(_ note: Notification) {
        if note.object as? NSTextField === year { suggest() }
        validate()
    }

    private func validate() {
        create.isEnabled = !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (template.yearLabel == nil || ShelfModel.projectYear(year.stringValue) != nil)
        let chosen = ShelfModel.projectYear(year.stringValue) ?? current
        preview.string = template.description(chosen) + "\n\nFolders\n" + template.folders.joined(separator: ", ")
            + "\n\nStarter checklist\n" + (template.checklist.isEmpty ? "No checklist." : template.checklist.map { "• " + $0 }.joined(separator: "\n"))
            + "\n\nProject guide\n" + template.projectGuide(chosen)
    }

    private func showYear() {
        let shown = template.yearLabel != nil
        yearLabel.stringValue = template.yearLabel ?? "Year"
        yearLabel.isHidden = !shown
        year.isHidden = !shown
    }

    /// A year still being typed leaves the name as it is.
    private func suggest() {
        let chosen = template.yearLabel != nil ? ShelfModel.projectYear(year.stringValue) : current
        guard let chosen else { return }
        let next = ShelfModel.suggestedName(template: template, year: chosen, empty: empty)
        name.stringValue = ShelfModel.followSuggestion(name: name.stringValue, last: last, next: next)
        last = next
    }
}
