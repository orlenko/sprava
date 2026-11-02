import BinderFormat
import SpravaKit
import SwiftUI

/// Visible deterministic controls for a binder's task (conversation.md §18.2): the circle completes it,
/// Edit opens ordinary fields, and Cancel to-do drops it. All writes use the runtime and op-log Undo.
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
        if let text = item.object?["details"]?.stringValue, !text.isEmpty { parts.append(text) }
        if let party = item.waitingOn { parts.append("waiting on \(party)") }
        if bucket == .nudge || bucket == .waiting, let due = item.due { parts.append("due \(due.description)") }
        if item.hasRecurrence { parts.append("repeats; the hub manages it for now") }
        if !item.tags.isEmpty { parts.append(item.tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts
    }

    /// Whether the row can be changed at all: an op names the item by its id, and an item that repeats is shown
    /// read-only, since the hub manages it for now (mvp.md feature 2).
    var changeable: Bool { editable && item.object?["id"] != nil && !item.hasRecurrence }
    /// A row that is not open closes at once; the open row closes through the editor, which saves what was typed first
    /// (Mark Done) or drops it with the item (Delete), so a closing the runtime refuses never takes the typed text.
    var closable: Bool { changeable && !editor.isEditing(item, in: folder) }
    var editing: Bool { changeable && editor.isEditing(item, in: folder) }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            circle
            if editing {
                ItemEditFields(actions: actions, editor: editor, folder: folder, reload: reload)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .onTapGesture { begin() }
                    if !dateText.isEmpty { Text(dateText).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                    if !details.isEmpty {
                        Text(details.joined(separator: "   ")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if changeable {
                    Button("Edit") { begin() }.disabled(actions.busy || editor.saving.contains(folder.standardizedFileURL))
                    Button("Cancel to-do") { close("drop") }
                        .disabled(actions.busy || editor.saving.contains(folder.standardizedFileURL))
                        .help("Cancel this to-do; Undo in Recent changes brings it back")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { begin() }
        .contextMenu {
            if changeable {
                Button("Edit") { begin() }
                Button("Mark Done") { close("complete") }
                Button("Delete") { close("drop") }
            }
        }
    }

    @ViewBuilder var circle: some View {
        let image = Image(systemName: item.priority == .high ? "exclamationmark.circle.fill" : "circle")
            .foregroundStyle(item.priority == .high ? .red : .secondary)
        if closable || editing {
            Button { close("complete") } label: { image }
                .buttonStyle(.plain)
                .disabled(actions.busy || editor.saving.contains(folder.standardizedFileURL))
                .accessibilityLabel(editing ? "Save and mark done" : "Mark done")
                .help(editing ? "Save and mark done" : "Mark done")
        } else {
            image
        }
    }

    func begin() {
        guard changeable else { return }
        editor.begin(item, in: folder, actions, reload: reload)
    }

    func close(_ op: String) {
        if editing {
            editor.close(as: op, in: folder, actions, reload: reload)
        } else if closable {
            actions.close(item, as: op, folder, reload: reload)
        }
    }
}

/// The open row of an item no longer on the page, shown apart with what was typed, until saved or cancelled.
struct StrandedItemEdit: View {
    @ObservedObject var actions: BinderActions
    @ObservedObject var editor: ItemEditor
    let folder: URL
    let page: NowPage
    let reload: () -> Void

    var body: some View {
        if editor.stranded(in: folder, shown: page) != nil {
            Section(header: Text("Being edited").font(.headline)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This item is no longer on the page: it was closed or changed elsewhere. Save what you typed, or cancel it.")
                        .font(.caption).foregroundStyle(.orange)
                    ItemEditFields(actions: actions, editor: editor, folder: folder, reload: reload, deletable: false)
                }
            }
        }
    }
}

/// The open row: the due date (or none) and the title. Return saves, Esc cancels.
struct ItemEditFields: View {
    @ObservedObject var actions: BinderActions
    @ObservedObject var editor: ItemEditor
    let folder: URL
    let reload: () -> Void
    /// False for a row whose item is no longer on the page, which there is nothing to delete from.
    var deletable = true
    @FocusState private var titleFocused: Bool

    var body: some View {
        let row = editor.row(in: folder)
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            TextField("Title", text: Binding(get: { editor.row(in: folder)?.title ?? "" },
                                             set: { editor.setTitle($0, in: folder) }))
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
          }
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
          }
          HStack {
            Button("Save") { save() }.disabled(actions.busy || row?.validation != nil)
            Button("Discard edits") { editor.cancel(in: folder) }.keyboardShortcut(.cancelAction)
            if deletable {
                Button("Done") { editor.close(as: "complete", in: folder, actions, reload: reload) }
                Button("Cancel to-do") { editor.close(as: "drop", in: folder, actions, reload: reload) }
                    .help("Cancel this to-do; Undo in Recent changes brings it back")
            }
          }
          TextField("Details", text: Binding(get: { editor.row(in: folder)?.details ?? "" },
                                              set: { editor.setDetails($0, in: folder) }), axis: .vertical)
              .textFieldStyle(.roundedBorder)
              .lineLimit(2...5)
          // Each label beside its menu, at the menu's own width: in a List row, labelled pickers in an HStack each
          // stretch to half the row and leave their labels far from their menus.
          HStack(spacing: 16) {
              LabeledPicker(label: "Priority", selection: Binding(get: { editor.row(in: folder)?.priority.rawValue ?? "normal" },
                  set: { if let value = Priority(rawValue: $0) { editor.setPriority(value, in: folder) } }),
                  options: [("High", "high"), ("Normal", "normal"), ("Low", "low")])
              LabeledPicker(label: "Status", selection: Binding(get: { editor.row(in: folder)?.status.rawValue ?? "open" },
                  set: { if let value = ItemStatus(rawValue: $0) { editor.setStatus(value, in: folder) } }),
                  options: [("Open", "open"), ("Waiting", "waiting"), ("Blocked", "blocked")])
              Spacer()
          }
          if row?.waiting == true {
              HStack {
                  TextField("Waiting on", text: Binding(get: { editor.row(in: folder)?.waitingOn ?? "" },
                                                       set: { editor.setWaitingOn($0, in: folder) }))
                  if let day = row?.followUp {
                      DatePicker("Follow up", selection: Binding(get: { ItemEditor.date(editor.row(in: folder)?.followUp ?? day) },
                          set: { editor.setFollowUp(ItemEditor.day($0), in: folder) }), displayedComponents: .date)
                          .datePickerStyle(.field)
                  } else {
                      Button("Add follow-up date") { editor.setFollowUp(CalendarDate.today(), in: folder) }
                  }
              }
              if let message = row?.validation { Text(message).font(.caption).foregroundStyle(.secondary) }
          }
        }
        // Locked while its change is on its way: the request already holds what was typed.
        .disabled(actions.busy || editor.saving.contains(folder.standardizedFileURL))
        .onSubmit { save() }
        .onExitCommand { editor.cancel(in: folder) }
        .onAppear { titleFocused = true }
    }

    func save() { editor.save(in: folder, actions, reload: reload) }
}

/// A short label and its menu, kept together at the menu's natural width.
struct LabeledPicker: View {
    let label: String
    let selection: Binding<String>
    let options: [(String, String)]

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Picker(label, selection: selection) {
                ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}
