import Combine
import Foundation
import Shelf
import SwiftUI

/// Window-owned navigation only: changing surfaces never changes a draft or a running turn.
@MainActor
final class BinderWorkspaceSelection: ObservableObject {
    enum Surface: String, CaseIterable, Hashable { case conversation = "Conversation", project = "Project" }
    @Published private var choices: [URL: Surface] = [:]

    func surface(for folder: URL, hasConversation: Bool) -> Surface {
        choices[folder.standardizedFileURL] ?? (hasConversation ? .conversation : .project)
    }

    func choose(_ surface: Surface, for folder: URL) {
        choices[folder.standardizedFileURL] = surface
    }
}

struct BinderWorkspace<Project: View>: View {
    @ObservedObject var model: ClaudeBinderConversation
    @ObservedObject var selection: BinderWorkspaceSelection
    let row: ShelfRow
    let conversation: ConversationSection
    let project: Project

    var body: some View {
        let current = selection.surface(for: row.folder, hasConversation:
            model.folder == row.folder && (model.connected ||
                (model.chat.folder == row.folder && ChatView.showsWhileDisconnected(model.chat))))
        VStack(spacing: 0) {
            Picker("Binder view", selection: Binding(get: { current }, set: { selection.choose($0, for: row.folder) })) {
                ForEach(BinderWorkspaceSelection.Surface.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)
            .padding(.horizontal, 16).padding(.vertical, 8)
            // Keep both surfaces mounted: navigation must not cancel polling, recreate editors or move the reader.
            ZStack {
                project.opacity(current == .project ? 1 : 0)
                    .disabled(current != .project).allowsHitTesting(current == .project)
                    .accessibilityHidden(current != .project)
                conversation.opacity(current == .conversation ? 1 : 0)
                    .disabled(current != .conversation).allowsHitTesting(current == .conversation)
                    .accessibilityHidden(current != .conversation)
            }
        }
    }
}

/// Geometry caused by a growing reply must not be mistaken for the reader scrolling away.
@MainActor
final class ConversationViewport: ObservableObject {
    @Published private(set) var followsLatest = true
    private var readerScrolling = false

    func scrolling(_ active: Bool) { readerScrolling = active }
    func measured(atBottom: Bool, movedEarlier: Bool = false) {
        if readerScrolling || movedEarlier || atBottom { followsLatest = atBottom }
    }
    func jumpToLatest() { readerScrolling = false; followsLatest = true }
}
