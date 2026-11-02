import BinderFormat
import Shelf
import SpravaKit
import SwiftUI

/// What is open in every binder on the Shelf, on one page: counts, a line to add an item to a binder, a search,
/// and the groups of binder-v0 §5.2. A row opens its binder's page; its circle marks it done.
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

    var body: some View {
        List {
            Section {
                Text("To-dos").font(.title2.bold())
                counts
                QuickAdd(model: model, targets: targets, contexts: board.contexts, reload: reload)
                filters
                if let change = model.lastChange {
                    HStack {
                        Text(change.line).lineLimit(1).foregroundStyle(.secondary)
                        Button("Undo") { Task { await model.undo(reload: reload) } }.buttonStyle(.link)
                    }
                }
                if let message = model.message { Text(message).foregroundStyle(.orange) }
            }
            ForEach(model.editingTargets) { target in
                TodoEditingPanel(actions: model.actions(for: target.folder), editor: editor, target: target, reload: reload)
            }
            list
        }
    }

    var counts: some View {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 14) {
            Text("\(board.openCount) open")
            if board.count(.overdue) > 0 { Text("\(board.count(.overdue)) overdue").foregroundStyle(.red) }
            Text("\(board.count(.today)) today")
          }
          HStack(spacing: 14) {
            Text("\(board.count(.next7)) in the next 7 days")
            Text("\(board.count(.waiting)) waiting")
          }
        }
        .foregroundStyle(.secondary)
    }

    var filters: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search title, tag, binder or id", text: $model.filter.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
          HStack(spacing: 12) {
            Toggle("High only", isOn: $model.filter.highOnly)
            if !board.contexts.isEmpty {
                Picker("Where am I", selection: $model.filter.context) {
                    Text("Everywhere").tag(String?.none)
                    ForEach(board.contexts, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .fixedSize()
            }
            Spacer()
            Button(model.collapsed.isEmpty ? "Collapse all" : "Expand all") {
                model.collapsed = model.collapsed.isEmpty ? Set(TodoBoard.Group.allCases) : []
            }
            .buttonStyle(.link)
          }
        }
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
                                TodoRow(entry: entry, today: board.today,
                                        complete: { Task { await model.complete(entry, editor: editor, reload: reload) } },
                                        cancel: { Task { await model.cancel(entry, editor: editor, reload: reload) } },
                                        edit: { Task { await model.edit(entry, editor: editor, reload: reload) } },
                                        open: { open(entry.folder) })
                            }
                        }
                    } header: {
                        Button { model.toggle(group) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: model.collapsed.contains(group) ? "chevron.right" : "chevron.down")
                                    .font(.caption).frame(width: 12)
                                Text("\(group.title) (\(entries.count))").font(.headline)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
        }
    }
}

struct QuickAdd: View {
    @ObservedObject var model: TodoModel
    let targets: [TodoModel.Target]
    let contexts: [String]
    let reload: () async -> Void

    /// The page's contexts, and the common ones of binder-v0 §5.9.
    var offered: [String] { Array(Set(contexts + ["@calls", "@computer", "@errands", "@online"])).sorted() }

    var target: TodoModel.Target? {
        let folder = model.defaultBinder(targets)
        return targets.first { $0.folder == folder }
    }

    func add() { Task { await model.add(to: target, reload: reload) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add a to-do", text: $model.draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targets.isEmpty)
            }
            TextField("Description (optional)", text: $model.details, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            HStack {
                Toggle("Due", isOn: $model.hasDue).fixedSize()
                DatePicker("Due", selection: $model.due, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field).disabled(!model.hasDue)
                Picker("Priority", selection: $model.priority) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            HStack {
                Picker("Context", selection: $model.context) {
                    Text("No context").tag(String?.none)
                    ForEach(offered, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("Binder", selection: Binding(get: { model.defaultBinder(targets) }, set: { model.binder = $0 })) {
                    ForEach(targets) { Text($0.label).tag(URL?.some($0.folder)) }
                }.disabled(targets.isEmpty)
            }
        }
        .disabled(model.adding)
    }
}

struct TodoRow: View {
    let entry: TodoBoard.Entry
    let today: CalendarDate
    let complete: () -> Void
    var cancel: () -> Void = {}
    var edit: () -> Void = {}
    let open: () -> Void

    var item: Item { entry.item }

    var date: (text: String, color: Color) {
        switch entry.bucket {
        case .nudge: (item.followUpAt.map { "chase \($0)" } ?? "chase now", .orange)
        case .waiting: (item.followUpAt.map { "chase \($0)" } ?? "", .secondary)
        case .overdue: (item.due?.description ?? "", .red)
        default: (item.due?.description ?? "", .secondary)
        }
    }

    /// The binder and the item's id; an id minted in this binder already starts with its name.
    var chip: String {
        let id = item.idText
        return id.hasPrefix(entry.binder + "-") ? id : "\(entry.binder) · \(id)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: complete) {
                Image(systemName: "circle").foregroundStyle(item.priority == .high ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!entry.closable)
            .accessibilityLabel("Mark done")
            .help(entry.closable ? "Mark done" : item.hasRecurrence ? "Repeats; the hub manages it for now" : "Open the binder to change it")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).lineLimit(2)
                if let party = item.waitingOn {
                    Text("waiting on \(party)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    ForEach(item.contexts.prefix(3), id: \.self) { TodoChip(text: $0) }
                    Text(date.text).font(.caption).monospacedDigit().foregroundStyle(date.color)
                    Spacer(minLength: 0)
                    TodoChip(text: chip).help("Open \(entry.binder)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            VStack(alignment: .trailing, spacing: 4) {
                Button("Edit", action: edit)
                Button("Cancel to-do", action: cancel)
            }.disabled(!entry.closable)
        }
        .padding(.vertical, 1)
    }
}

struct TodoChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(.secondary)
    }
}
