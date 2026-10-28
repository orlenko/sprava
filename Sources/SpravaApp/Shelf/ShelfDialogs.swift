import AppKit
import BinderStore

/// A new binder's template key, its name and its year, as typed in the alert.
typealias NewBinderAnswer = (template: String, name: String, year: String)

/// The Shelf's dialogs. The model asks through closures that default to these, so tests show no UI.
extension ShelfModel {
    /// The template, name and, for a tax year, the year, asked in one alert. `year` is the current year, the year field's
    /// first value. For an empty folder the name starts from the folder's own, in the shape a new binder's name takes,
    /// and the folder is renamed to it when they differ. The name follows the template and the year until the person
    /// types one of their own. Any name and year are returned as typed; the model checks the year (`taxYear`) and turns
    /// the name into a valid one (`binderName`).
    static func binderAlert(empty: URL?, year: Int) -> NewBinderAnswer? {
        let alert = NSAlert()
        let shape = "The folder is named in lowercase with hyphens: Maple Street becomes maple-street. A template's checklist arrives as one card to approve."
        if let empty {
            alert.messageText = "Make \u{201C}\(empty.lastPathComponent)\u{201D} a new binder?"
            alert.informativeText = "The folder is empty. Pick a starting point and a name. \(shape)"
        } else {
            alert.messageText = "New binder"
            alert.informativeText = "Pick a starting point and a name. \(shape)"
        }
        let fields = NewBinderFields(empty: empty, year: year)
        alert.accessoryView = fields.box
        alert.addButton(withTitle: empty == nil ? "Choose Where…" : "Make Binder")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (fields.template.key, fields.name.stringValue, fields.year.stringValue)
    }

    /// Whether a template's binder is for one year, which the person picks.
    static func asksYear(_ template: String) -> Bool { template == BinderTemplate.taxYear.key }

    /// The year typed for a tax year: four digits, from 1900 to the year after `current`; nil for anything else. Compared,
    /// never made a range, so a `current` below 1900 refuses every year instead of trapping.
    static func taxYear(_ typed: String, current: Int) -> Int? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard text.count == 4, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), let year = Int(text),
              year >= 1900, year <= current + 1 else { return nil }
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

/// The new-binder alert's fields: the template picker, the year (shown for a tax year only) and the name, which follows
/// the other two until the person types their own.
@MainActor
private final class NewBinderFields: NSObject, NSTextFieldDelegate {
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 88))
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 60, width: 260, height: 26))
    let yearLabel = NSTextField(labelWithString: "Tax year")
    let year = NSTextField(frame: NSRect(x: 70, y: 30, width: 70, height: 24))
    let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    private let templates = BinderTemplate.all
    private let empty: URL?
    private let current: Int
    private var last: String

    var template: BinderTemplate { templates[max(0, picker.indexOfSelectedItem)] }

    init(empty: URL?, year current: Int) {
        self.empty = empty
        self.current = current
        last = ShelfModel.suggestedName(template: templates[0], year: current, empty: empty)
        super.init()
        picker.addItems(withTitles: templates.map(\.title))
        picker.target = self
        picker.action = #selector(templateChanged)
        yearLabel.frame = NSRect(x: 0, y: 33, width: 66, height: 18)
        year.stringValue = String(current)
        year.delegate = self
        name.stringValue = last
        for view in [picker, yearLabel, year, name] { box.addSubview(view) }
        showYear()
    }

    @objc func templateChanged() {
        showYear()
        suggest()
    }

    func controlTextDidChange(_ note: Notification) {
        if note.object as? NSTextField === year { suggest() }
    }

    private func showYear() {
        let shown = ShelfModel.asksYear(template.key)
        yearLabel.isHidden = !shown
        year.isHidden = !shown
    }

    /// A year still being typed leaves the name as it is.
    private func suggest() {
        let chosen = ShelfModel.asksYear(template.key) ? ShelfModel.taxYear(year.stringValue, current: current) : current
        guard let chosen else { return }
        let next = ShelfModel.suggestedName(template: template, year: chosen, empty: empty)
        name.stringValue = ShelfModel.followSuggestion(name: name.stringValue, last: last, next: next)
        last = next
    }
}
