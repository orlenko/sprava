import BinderFormat
import SpravaKit
import SwiftUI

/// One item on the binder's page. On an adopted binder the circle marks it done, a click on the title (or a double
/// click on the row) edits its title and due date in place, and the context menu offers Edit, Mark Done and Delete.
/// Each is one op through the runtime; a closing is undone from Recent changes.
struct ItemRow: View {
    let item: Item
    let bucket: Bucket
    @ObservedObject var actions: BinderActions
    @ObservedObject var editor: ItemEditor
    let folder: URL
    /// False on a binder Sprava does not manage yet: the row only shows the item.
    let editable: Bool
    let reload: () -> Void

    var dateText: String {
        if bucket == .nudge || bucket == .waiting {
            return item.followUpAt.map { "chase \($0)" } ?? "chase now"
        }
        return item.due?.description ?? ""
    }

    var details: [String] {
        var parts: [String] = []
        if let party = item.waitingOn { parts.append("waiting on \(party)") }
        if bucket == .nudge || bucket == .waiting, let due = item.due { parts.append("due \(due.description)") }
        if item.hasRecurrence { parts.append("repeats; the hub manages it for now") }
        if !item.tags.isEmpty { parts.append(item.tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts
    }

    /// Whether the row can be changed at all: an op names the item by its id.
    var changeable: Bool { editable && item.object?["id"] != nil }
    /// A recurring item is advanced, not closed, and the hub does that for now. An open row is saved or cancelled
    /// first, so a closing the runtime refuses never takes what was typed with it.
    var closable: Bool { changeable && !item.hasRecurrence && !editor.isEditing(item, in: folder) }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            circle
            if changeable, editor.isEditing(item, in: folder) {
                ItemEditFields(actions: actions, editor: editor, folder: folder, reload: reload)
            } else {
                Text(dateText).monospacedDigit().foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .onTapGesture { begin() }
                    if !details.isEmpty {
                        Text(details.joined(separator: "   ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { begin() }
        .contextMenu {
            if changeable {
                Button("Edit") { begin() }
                if closable {
                    Button("Mark Done") { close("complete") }
                    Button("Delete") { close("drop") }
                }
            }
        }
    }

    @ViewBuilder var circle: some View {
        let image = Image(systemName: item.priority == .high ? "exclamationmark.circle.fill" : "circle")
            .foregroundStyle(item.priority == .high ? .red : .secondary)
        if closable {
            Button { close("complete") } label: { image }
                .buttonStyle(.plain)
                .disabled(actions.busy)
                .help("Mark done")
        } else {
            image
        }
    }

    func begin() {
        guard changeable else { return }
        editor.begin(item, in: folder, actions, reload: reload)
    }

    func close(_ op: String) {
        guard closable else { return }
        actions.close(item, as: op, folder, reload: reload)
    }
}

/// The open row: the due date (or none) and the title. Return saves, Esc cancels.
struct ItemEditFields: View {
    @ObservedObject var actions: BinderActions
    @ObservedObject var editor: ItemEditor
    let folder: URL
    let reload: () -> Void
    @FocusState private var titleFocused: Bool

    var body: some View {
        let row = editor.row(in: folder)
        HStack(alignment: .firstTextBaseline) {
            if let due = row?.due {
                DatePicker("Due", selection: Binding(get: { ItemEditor.date(editor.row(in: folder)?.due ?? due) },
                                                     set: { editor.setDue(ItemEditor.day($0), in: folder) }),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                Button("No date") { editor.setDue(nil, in: folder) }.font(.caption)
            } else {
                Button("Add date") { editor.setDue(CalendarDate.today(), in: folder) }.font(.caption)
            }
            TextField("Title", text: Binding(get: { editor.row(in: folder)?.title ?? "" },
                                             set: { editor.setTitle($0, in: folder) }))
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
            Button("Save") { save() }.disabled(actions.busy)
            Button("Cancel") { editor.cancel(in: folder) }.keyboardShortcut(.cancelAction)
        }
        // Locked while its change is on its way: the request already holds what was typed.
        .disabled(editor.saving.contains(folder.standardizedFileURL))
        .onSubmit { save() }
        .onExitCommand { editor.cancel(in: folder) }
        .onAppear { titleFocused = true }
    }

    func save() { editor.save(in: folder, actions, reload: reload) }
}
