import SwiftUI

/// What the row itself cannot show: why a change was refused, its Undo, and the fields of an open row that has left the page
/// because a new date or a filter moved it (D25).
struct TodoEditingPanel: View {
    @ObservedObject var actions: BinderActions
    @ObservedObject var editor: ItemEditor
    let target: TodoModel.Target
    var stranded = true
    let reload: () async -> Void

    var body: some View {
        Section(stranded ? "Edit to-do \u{00b7} " + target.label : target.label) {
            if stranded, editor.row(in: target.folder) != nil {
                ItemEditFields(actions: actions, editor: editor, folder: target.folder, reload: refresh)
            }
            if let message = actions.message { Text(message).foregroundStyle(.orange) }
            if actions.moved != nil {
                MovedLine(actions: actions, folder: target.folder, reload: refresh)
            } else if let change = actions.history.first {
                HStack {
                    Text(change.line).lineLimit(2)
                    if change.undoable && !change.undone {
                        Button("Undo") { actions.undo(change, target.folder, reload: refresh) }
                            .disabled(actions.busy)
                    }
                }
            }
        }
    }
    func refresh() {
        Task {
            await actions.loadReview(target.folder)
            await reload()
        }
    }
}

/// Where the last Done moved a repeating to-do, with its Undo: "Done: … Next: December 15. Undo".
struct MovedLine: View {
    @ObservedObject var actions: BinderActions
    let folder: URL
    let reload: () -> Void

    var body: some View {
        if let moved = actions.moved {
            HStack {
                Text(moved.line).lineLimit(2)
                Button("Undo") { actions.undoMoved(folder, reload: reload) }.buttonStyle(.link).disabled(actions.busy)
            }
        }
    }
}

/// Per-binder direct-add drafts outlive their Project view and participate in close/quit protection.
@MainActor
final class BinderTodoModels: ObservableObject, DraftOwner {
    private var models: [URL: TodoModel] = [:]
    func model(for folder: URL) -> TodoModel {
        let folder = folder.standardizedFileURL
        if let model = models[folder] { return model }
        let model = TodoModel(); models[folder] = model
        return model
    }
    var draftState: DraftState { models.values.reduce(DraftState()) { $0.merging($1.draftState) } }
}

struct DirectTodoSection: View {
    @ObservedObject var model: TodoModel
    let target: TodoModel.Target
    let reload: () async -> Void
    var body: some View {
        Section {
            QuickAdd(model: model, targets: [target], contexts: [], reload: reload)
            if let message = model.message { Text(message).foregroundStyle(.orange) }
            if let change = model.lastChange {
                HStack {
                    Text(change.line)
                    Button("Undo") { Task { await model.undo(reload: reload) } }.disabled(model.undoing)
                }
            }
        }
    }
}
