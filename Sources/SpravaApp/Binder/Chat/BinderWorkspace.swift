import AppKit
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

/// Conversation and Project side by side, Project in about a third of the width; one at a time, with a switch between
/// them, where the two would not both have room.
struct BinderColumns: Equatable {
    let sideBySide: Bool
    let conversation: CGFloat
    let project: CGFloat
    static let narrowestProject: CGFloat = 380
    static let narrowestConversation: CGFloat = 480
    init(width: CGFloat) {
        sideBySide = width >= Self.narrowestProject + Self.narrowestConversation
        project = sideBySide ? max(Self.narrowestProject, (width / 3).rounded()) : width
        conversation = sideBySide ? width - project : width
    }
}

struct BinderWorkspace<Project: View>: View {
    @ObservedObject var model: ClaudeBinderConversation
    @ObservedObject var selection: BinderWorkspaceSelection
    let row: ShelfRow
    let conversation: ConversationSection
    let project: Project

    var body: some View {
        // No VStack of two frames and no `if`: both surfaces stay mounted at every width, since navigation must not cancel
        // polling, recreate editors or move the reader.
        GeometryReader { geometry in
            let columns = BinderColumns(width: geometry.size.width)
            let current = selection.surface(for: row.folder, hasConversation:
                model.folder == row.folder && (model.connected ||
                    (model.chat.folder == row.folder && ChatView.showsWhileDisconnected(model.chat))))
            VStack(spacing: 0) {
                if !columns.sideBySide {
                    Picker("Binder view", selection: Binding(get: { current }, set: { selection.choose($0, for: row.folder) })) {
                        ForEach(BinderWorkspaceSelection.Surface.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                ZStack(alignment: .topLeading) {
                    surface(project, shown: columns.sideBySide || current == .project)
                        .frame(width: columns.project)
                        .offset(x: columns.sideBySide ? columns.conversation : 0)
                    surface(conversation, shown: columns.sideBySide || current == .conversation)
                        .frame(width: columns.conversation)
                    if columns.sideBySide {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).offset(x: columns.conversation)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func surface(_ view: some View, shown: Bool) -> some View {
        view.opacity(shown ? 1 : 0)
            .disabled(!shown).allowsHitTesting(shown)
            .accessibilityHidden(!shown)
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
