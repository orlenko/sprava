import BinderFormat
import SpravaKit
import SwiftUI

/// Whether a to-do list has the width for its priority and binder columns.
struct TodoListIsWideKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var todoListIsWide: Bool {
        get { self[TodoListIsWideKey.self] }
        set { self[TodoListIsWideKey.self] = newValue }
    }
}

extension View {
    /// Tells the to-do rows in this list what columns they have room for.
    func measuringTodoWidth(_ wide: Binding<Bool>) -> some View {
        onGeometryChange(for: Bool.self) { $0.size.width >= TodoColumns.wideFrom } action: { wide.wrappedValue = $0 }
            .environment(\.todoListIsWide, wide.wrappedValue)
    }
}

/// The columns that line up down a to-do list, in the add row and every row under it.
enum TodoColumns {
    static let wideFrom: CGFloat = 640
    static let leading: CGFloat = 20
    static let date: CGFloat = 84
    static let priority: CGFloat = 50
    static let binder: CGFloat = 100
    static let spacing: CGFloat = 10
}

/// One to-do, on a binder's page or the To-dos page: its ring, title, a second line only when there is something to say, then
/// its date and, with room, priority and binder. Click a value to change it; Return or moving away saves, Esc puts it back.
/// The row moves to its new group only once it has saved and closed. Everything else about an item is under More. All writes go
/// through `ItemEditor` and the runtime, with op-log Undo (D25).
struct TodoLine: View {
    let item: Item
    let bucket: Bucket
    let today: CalendarDate
    /// False while the row can only be read: a binder that cannot be written, an item that repeats or has no id.
    let changeable: Bool
    /// Beside the row on a page of many binders; nil on a binder's own page.
    var binder: String?
    @ObservedObject var actions: BinderActions
    @ObservedObject var editor: ItemEditor
    let folder: URL
    let begin: () -> Void
    let complete: () -> Void
    let cancel: () -> Void
    var open: (() -> Void)?
    let reload: () -> Void

    @Environment(\.todoListIsWide) private var wide
    @State private var firstField = TodoLineEditor.Field.title
    @State private var more = false
    @State private var hovering = false

    private var editing: Bool { editor.isEditing(item, in: folder) }

    /// What a row says under its title.
    static func secondLine(_ item: Item, bucket: Bucket) -> String {
        var parts: [String] = []
        if let text = item.object?["details"]?.stringValue, !text.isEmpty { parts.append(text) }
        if let party = item.waitingOn { parts.append("waiting on \(party)") }
        if bucket == .nudge || bucket == .waiting, let due = item.due { parts.append("due \(due.description)") }
        if item.hasRecurrence { parts.append("repeats; the hub manages it for now") }
        if !item.contexts.isEmpty { parts.append(item.contexts.joined(separator: " ")) }
        if !item.tags.isEmpty { parts.append(item.tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts.joined(separator: "   ")
    }

    /// The date column: a follow-up for what is waiting, otherwise the due date.
    static func dateText(_ item: Item, bucket: Bucket, today: CalendarDate) -> (text: String, color: Color) {
        switch bucket {
        case .nudge: (item.followUpAt.map { "chase " + TodoDates.label($0, today: today) } ?? "chase now", .orange)
        case .waiting: (item.followUpAt.map { "chase " + TodoDates.label($0, today: today) } ?? "chase now", .secondary)
        case .overdue: (item.due.map { TodoDates.label($0, today: today) } ?? "", .red)
        case .today: (item.due.map { TodoDates.label($0, today: today) } ?? "", .orange)
        default: (item.due.map { TodoDates.label($0, today: today) } ?? "", .secondary)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ring
            if editing, more {
                ItemEditFields(actions: actions, editor: editor, folder: folder, reload: reload)
            } else if editing {
                TodoLineEditor(actions: actions, editor: editor, folder: folder, today: today, first: firstField,
                               binder: binder, more: { more = true }, reload: reload)
            } else {
                reading
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { if changeable { menuItems } }
        .onChange(of: editing) { _, open in if !open { more = false } }
    }

    private var ring: some View {
        Button(action: complete) {
            Image(systemName: "circle").foregroundStyle(item.priority == .high ? Color.red : Color.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: TodoColumns.leading)
        .disabled(!changeable)
        .accessibilityLabel("Mark done")
        .help(changeable ? "Mark done" : item.hasRecurrence ? "Repeats; the hub manages it for now" : "Open the binder to change it")
    }

    private var reading: some View {
        let date = Self.dateText(item, bucket: bucket, today: today)
        let second = Self.secondLine(item, bucket: bucket)
        return HStack(alignment: .firstTextBaseline, spacing: TodoColumns.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(2)
                if !second.isEmpty { Text(second).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { edit(.title) }
            Text(date.text).font(.system(size: 12).monospacedDigit()).foregroundStyle(date.color)
                .lineLimit(1).frame(minWidth: TodoColumns.date, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { edit(.date) }
            if wide {
                Text(item.priority == .high ? "High" : item.priority == .low ? "Low" : "")
                    .font(.system(size: 12)).foregroundStyle(item.priority == .high ? Color.red : Color.secondary)
                    .frame(width: TodoColumns.priority, alignment: .leading)
            }
            if wide, let binder {
                Text(binder).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: TodoColumns.binder, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { open?() }
                    .help("Open \(binder)")
            }
            actionsMenu
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Edit") { edit(.title) }
    }

    /// In reach without a right-click, and out of the way until the pointer is on the row.
    private var actionsMenu: some View {
        Menu { menuItems } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .frame(width: 16)
            .opacity(hovering && changeable ? 1 : 0)
            .disabled(!changeable)
            .accessibilityLabel("More for this to-do")
    }

    @ViewBuilder private var menuItems: some View {
        Button("Edit") { edit(.title) }
        Button("More\u{2026}") { more = true; edit(.title) }
        Button("Mark Done", action: complete)
        Button("Cancel to-do", action: cancel)
        if let open, let binder { Button("Open \(binder)", action: open) }
    }

    private func edit(_ field: TodoLineEditor.Field) {
        guard changeable else { return }
        firstField = field
        begin()
    }
}

/// A row being changed, in place: the same columns, as fields. What was typed lives in `ItemEditor`, so it survives this view.
struct TodoLineEditor: View {
    enum Field: Hashable { case title, date, details }

    @ObservedObject var actions: BinderActions
    @ObservedObject var editor: ItemEditor
    let folder: URL
    let today: CalendarDate
    let first: Field
    let binder: String?
    let more: () -> Void
    let reload: () -> Void

    @Environment(\.todoListIsWide) private var wide
    @FocusState private var focus: Field?
    @State private var dateText = ""
    @State private var dateRefused = false

    private var locked: Bool { actions.busy || editor.saving.contains(folder.standardizedFileURL) }
    private var editsFollowUp: Bool { editor.row(in: folder)?.waiting == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: TodoColumns.spacing) {
                TextField("Title", text: Binding(get: { editor.row(in: folder)?.title ?? "" }, set: { editor.setTitle($0, in: folder) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .title)
                TextField(editsFollowUp ? "Chase" : "Due", text: $dateText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: TodoColumns.date)
                    .focused($focus, equals: .date)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(dateRefused ? Color.orange : Color.clear))
                    .help("Today, tomorrow, fri, +3, nov 12, 11/12 or 2031-02-03; empty for no date")
                if wide {
                    Menu(TodoPriorityLabel.text(editor.row(in: folder)?.priority ?? .normal)) {
                        ForEach(Priority.allCases, id: \.self) { value in
                            Button(TodoPriorityLabel.text(value)) { editor.setPriority(value, in: folder) }
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: TodoColumns.priority, alignment: .leading)
                }
                if wide, let binder {
                    Text(binder).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: TodoColumns.binder, alignment: .leading)
                }
                Spacer().frame(width: 16)
            }
            TextField("Description", text: Binding(get: { editor.row(in: folder)?.details ?? "" }, set: { editor.setDetails($0, in: folder) }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .font(.caption)
                .focused($focus, equals: .details)
            if dateRefused {
                Text("Sprava could not read that date. Try tomorrow, fri, nov 12 or 2031-02-03.").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Button("More\u{2026}", action: more).buttonStyle(.link).font(.caption)
                Text("Return saves, Esc puts it back").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .disabled(locked)
        .onAppear {
            dateText = shownDate
            focus = first
        }
        .onChange(of: focus) { _, now in if now == nil { commit() } }
        .onChange(of: dateText) { _, typed in
            dateRefused = false
            apply(typed)
        }
        .onSubmit(commit)
        .onExitCommand { editor.cancel(in: folder) }
    }

    /// The date in the open row, which may already differ from the item's after a visit to More.
    private var shownDate: String {
        guard let row = editor.row(in: folder), let day = row.waiting ? row.followUp : row.due else { return "" }
        return TodoDates.label(day, today: today)
    }

    /// The date when the row opened, as its field first showed it.
    private var initialDate: String {
        guard let row = editor.row(in: folder), let day = row.item.status != .open ? row.item.followUpAt : row.item.due else { return "" }
        return TodoDates.label(day, today: today)
    }

    /// Puts a date as soon as it can be read into the open row, so it goes wherever the row's other changes go: saved when
    /// another row is opened, kept when More opens.
    private func apply(_ typed: String) {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != initialDate else { return }
        let day = text.isEmpty ? nil : TodoDates.parse(text, today: today)
        guard text.isEmpty || day != nil else { return }
        if editsFollowUp { editor.setFollowUp(day, in: folder) } else { editor.setDue(day, in: folder) }
    }

    /// Saves unless the date cannot be read, which stays open to be fixed. An unchanged row just closes.
    private func commit() {
        guard !locked, editor.row(in: folder) != nil else { return }
        let typed = dateText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, typed != initialDate, TodoDates.parse(typed, today: today) == nil {
            dateRefused = true
            return
        }
        editor.save(in: folder, actions, reload: reload)
    }
}

enum TodoPriorityLabel {
    static func text(_ priority: Priority) -> String { priority.rawValue.capitalized }
}

/// A group's heading, the same on both pages.
struct TodoGroupHeading: View {
    let title: String
    let count: Int
    let bucket: Bucket?
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
    private var tint: Color {
        switch bucket {
        case .overdue: .red
        case .today, .nudge: .orange
        case .waiting: .blue
        default: .secondary
        }
    }
}
