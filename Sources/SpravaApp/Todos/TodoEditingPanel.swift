import SwiftUI

/// Editing stays reachable even if a new date/filter removes the original row from its group (D25).
struct TodoEditingPanel: View {
    @ObservedObject var actions: BinderActions
    @ObservedObject var editor: ItemEditor
    let target: TodoModel.Target
    let reload: () async -> Void

    var body: some View {
        Section("Edit to-do · " + target.label) {
            if editor.row(in: target.folder) != nil {
                ItemEditFields(actions: actions, editor: editor, folder: target.folder, reload: refresh)
            }
            if let message = actions.message { Text(message).foregroundStyle(.orange) }
            if let change = actions.history.first {
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
        Section("Add a to-do directly") {
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
