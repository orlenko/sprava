import BinderFormat
import Shelf
import SpravaKit
import SwiftUI

/// What is open in every binder on the Shelf, on one page: counts, a row to add an item to a binder, a search, and the groups
/// of binder-v0 §5.2. A row is changed in place (`TodoLine`); its circle marks it done; its binder's name opens that binder.
struct TodosView: View {
    @ObservedObject var model: TodoModel
    @ObservedObject var editor = ItemEditor()
    let board: TodoBoard
    let rows: [ShelfRow]
    let open: (URL) -> Void
    let reload: () async -> Void

    /// The binders an item can be added to, as the Inbox offers them: adopted and writable.
    var targets: [TodoModel.Target] {
        let adopted = rows.filter { $0.teka.isAdopted && !$0.teka.writesBlocked }
        return adopted.map { row in
            let shared = adopted.filter { InboxView.fold($0.name) == InboxView.fold(row.name) }.count > 1
            return TodoModel.Target(folder: row.folder, label: InboxView.label(name: row.name, folder: row.folder, sharesName: shared))
        }
    }

    @State private var wide = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("To-dos").font(.title2.bold())
                    Spacer()
                    counts
                }
                QuickAdd(model: model, targets: targets, contexts: board.contexts, offersGeneral: true, reload: reload)
                filters
                if let change = model.lastChange {
                    HStack {
                        Text(change.line).lineLimit(1).foregroundStyle(.secondary)
                        Button("Undo") { Task { await model.undo(reload: reload) } }.buttonStyle(.link)
                    }
                }
                if let message = model.message { Text(message).foregroundStyle(.orange) }
            }
            // An open row that has left the page comes first, so it stays in reach; an edit's Undo goes below, so that opening
            // a row never moves the list under the pointer.
            ForEach(model.editingTargets.filter { stranded(in: $0.folder) }) { target in
                TodoEditingPanel(actions: model.actions(for: target.folder), editor: editor, target: target, stranded: true, reload: reload)
            }
            list
            ForEach(model.editingTargets.filter { !stranded(in: $0.folder) }) { target in
                TodoEditingPanel(actions: model.actions(for: target.folder), editor: editor, target: target, stranded: false, reload: reload)
            }
        }
        .measuringTodoWidth($wide)
    }

    /// Whether the open row of this binder has left the page: changed so a filter hides it, or closed elsewhere.
    private func stranded(in folder: URL) -> Bool {
        guard editor.row(in: folder) != nil else { return false }
        return !TodoBoard.Group.allCases.contains { group in
            board.entries(group, model.filter).contains { $0.folder == folder && editor.isEditing($0.item, in: folder) && !model.collapsed.contains(group) }
        }
    }

    var counts: some View {
        HStack(spacing: 14) {
            Text("\(board.openCount) open")
            if board.count(.overdue) > 0 { Text("\(board.count(.overdue)) overdue").foregroundStyle(.red) }
            if board.count(.today) > 0 { Text("\(board.count(.today)) today").foregroundStyle(.orange) }
            if wide, board.count(.next7) > 0 { Text("\(board.count(.next7)) next 7 days") }
            if board.count(.waiting) > 0 { Text("\(board.count(.waiting)) waiting") }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder var filters: some View {
        if wide {
            HStack(spacing: 12) { search; Spacer(minLength: 0); filterControls; collapseAll }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                search
                HStack(spacing: 12) { filterControls; Spacer(minLength: 0); collapseAll }
            }
        }
    }

    private var search: some View {
        TextField("Search title, tag, binder or id", text: $model.filter.query)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)
    }

    @ViewBuilder private var filterControls: some View {
        Toggle("High only", isOn: $model.filter.highOnly)
        if !board.contexts.isEmpty {
            Picker("Where am I", selection: $model.filter.context) {
                Text("Everywhere").tag(String?.none)
                ForEach(board.contexts, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .fixedSize()
        }
    }

    private var collapseAll: some View {
        Button(model.collapsed.isEmpty ? "Collapse all" : "Expand all") {
            model.collapsed = model.collapsed.isEmpty ? Set(TodoBoard.Group.allCases) : []
        }
        .buttonStyle(.link)
    }

    @ViewBuilder var list: some View {
        let shown = TodoBoard.Group.allCases.map { ($0, board.entries($0, model.filter).filter { !model.closing.contains($0.id) }) }
        if board.openCount == 0 {
            Text("Nothing open. Items from every binder on the Shelf show here.").foregroundStyle(.secondary)
        } else if shown.allSatisfy({ $0.1.isEmpty }) {
            Text("No matching to-dos.").foregroundStyle(.secondary)
        } else {
                ForEach(shown.filter { !$0.1.isEmpty }, id: \.0) { group, entries in
                    Section {
                        if !model.collapsed.contains(group) {
                            ForEach(entries) { entry in
                                TodoLine(item: entry.item, bucket: entry.bucket, today: board.today, changeable: entry.closable,
                                         binder: entry.binder, actions: model.actions(for: entry.folder), editor: editor, folder: entry.folder,
                                         begin: { Task { await model.edit(entry, editor: editor, reload: reload) } },
                                         complete: { Task { await model.complete(entry, editor: editor, reload: reload) } },
                                         cancel: { Task { await model.cancel(entry, editor: editor, reload: reload) } },
                                         open: { open(entry.folder) },
                                         reload: { let writer = model.actions(for: entry.folder)
                                             Task { await writer.loadReview(entry.folder); await reload() } })
                            }
                        }
                    } header: {
                        Button { model.toggle(group) } label: {
                            HStack(spacing: 4) {
                                if model.collapsed.contains(group) {
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                }
                                TodoGroupHeading(title: group.title, count: entries.count, bucket: group == .waiting ? .waiting : entries.first?.bucket)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
        }
    }
}

/// The row at the top of a to-do list, in its columns. Return adds what was typed and leaves the cursor here for the next;
/// clicking away keeps it as a draft. Pasted lines add one to-do each. All that a to-do can also say is set once it is listed.
struct QuickAdd: View {
    @ObservedObject var model: TodoModel
    let targets: [TodoModel.Target]
    let contexts: [String]
    var offersGeneral = false
    let reload: () async -> Void

    @Environment(\.todoListIsWide) private var wide
    @FocusState private var titleFocused: Bool

    var target: TodoModel.Target? {
        let folder = offersGeneral ? model.binder : model.defaultBinder(targets)
        return targets.first { $0.folder == folder }
    }

    /// Keeps the field usable, and in focus, while the runtime writes: what is typed meanwhile stays for the next Return.
    func add() {
        titleFocused = true
        Task { await model.add(to: target, reload: reload) }
    }

    private var lineCount: Int { TodoModel.lines(model.draft).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                  .frame(width: TodoColumns.leading)
              HStack(alignment: .firstTextBaseline, spacing: TodoColumns.spacing) {
                TextField("", text: $model.draft, prompt: Text("Add a to-do, then Return").foregroundStyle(.tertiary), axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6)
                    .focused($titleFocused)
                    .onSubmit(add)
                    .accessibilityLabel("Add a to-do")
                TextField("", text: $model.dueText)
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.system(size: 12))
                    .frame(width: TodoColumns.date)
                    // Over the field rather than its prompt, which would sit at its left and out of the date column.
                    .overlay(alignment: .trailing) {
                        if model.dueText.isEmpty { Text("Due").font(.system(size: 12)).foregroundStyle(.tertiary).allowsHitTesting(false) }
                    }
                    .onSubmit(add)
                    .help("Today, tomorrow, fri, +3, nov 12, 11/12 or 2031-02-03")
                    .accessibilityLabel("Due date")
                if wide {
                    Menu(TodoPriorityLabel.text(model.priority)) {
                        ForEach(Priority.allCases, id: \.self) { value in
                            Button(TodoPriorityLabel.text(value)) { model.priority = value }
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: TodoColumns.priority, alignment: .leading)
                    .accessibilityLabel("Priority")
                    if offersGeneral {
                        Menu(target?.label ?? "General") {
                            Button("General") { model.binder = nil }
                            ForEach(targets) { option in Button(option.label) { model.binder = option.folder } }
                        }
                        .menuStyle(.button).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: TodoColumns.binder, alignment: .leading)
                        .accessibilityLabel("Binder")
                    }
                }
                Spacer().frame(width: 16)
              }
            }
            if lineCount > 1 {
                Text("\(lineCount) to-dos. Return adds them all.").font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, TodoColumns.leading + 8)
            }
        }
        .padding(.vertical, 6)
        // Behind the row and a little wider than it, so its columns line up with those of the rows under it.
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)).padding(.horizontal, -4))
    }
}
