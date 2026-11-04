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

    /// Opens where a binder's cards are: Project's To-dos, not its settings. In a narrow window Conversation would otherwise cover them.
    func showCards(in folder: URL) {
        choose(.project, for: folder)
        pageTab = .todos
        settings.remove(folder.standardizedFileURL)
    }

    /// The parts of Project, one at a time, so the documents and history are not below a long to-do list (issue #593).
    enum PageTab: String, CaseIterable, Hashable { case todos = "To-dos", explore = "Explore", history = "History" }
    /// One choice for the window, kept through reloads, polls, edits and other binders: a tab is picked for a task, such as finding
    /// a document, that often goes on in the next binder. A new window, so each launch, starts at To-dos.
    @Published var pageTab: PageTab = .todos

    /// Binders with no conversation yet where the person asked to talk, so the conversation shows beside Project.
    @Published private var opened: Set<URL> = []
    func opensConversation(_ folder: URL) -> Bool { opened.contains(folder.standardizedFileURL) }
    func setOpensConversation(_ open: Bool, for folder: URL) {
        if open { opened.insert(folder.standardizedFileURL) } else { opened.remove(folder.standardizedFileURL) }
    }

    /// Which binders are showing their settings instead of their working page.
    @Published private var settings: Set<URL> = []
    func showsSettings(_ folder: URL) -> Bool { settings.contains(folder.standardizedFileURL) }
    func toggleSettings(_ folder: URL) {
        let key = folder.standardizedFileURL
        if settings.remove(key) == nil { settings.insert(key) }
    }
}

/// Conversation and Project side by side in equal widths (decisions.md D37), or one at a time where the two would not both
/// have room. A binder with no conversation gives Project the whole page until the person asks to talk.
struct BinderColumns: Equatable {
    let sideBySide: Bool
    let conversation: CGFloat
    let project: CGFloat
    static let narrowestProject: CGFloat = 380
    static let narrowestConversation: CGFloat = 480
    static func hasRoom(_ width: CGFloat) -> Bool { width >= narrowestProject + narrowestConversation }
    init(width: CGFloat, talking: Bool = true) {
        sideBySide = talking && Self.hasRoom(width)
        project = sideBySide ? min(width - Self.narrowestConversation, max(Self.narrowestProject, (width / 2).rounded())) : width
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
            let hasConversation = model.folder == row.folder && (model.connected ||
                (model.chat.folder == row.folder && ChatView.showsWhileDisconnected(model.chat)))
            let room = BinderColumns.hasRoom(geometry.size.width)
            let talking = hasConversation || selection.opensConversation(row.folder)
            let columns = BinderColumns(width: geometry.size.width, talking: talking)
            let current = room && !talking ? BinderWorkspaceSelection.Surface.project : selection.surface(for: row.folder, hasConversation: hasConversation)
            VStack(spacing: 0) {
                if room && !talking {
                    HStack(spacing: 10) {
                        Button { selection.setOpensConversation(true, for: row.folder) } label: {
                            Label("Talk to Sprava", systemImage: "bubble.left.and.bubble.right")
                        }
                        Text("Ask about this binder, find a source, or draft an email.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                } else if !room {
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
                    surface(conversationSurface(hideable: room && !hasConversation), shown: columns.sideBySide || current == .conversation)
                        .frame(width: columns.conversation)
                    if columns.sideBySide {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).offset(x: columns.conversation)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func conversationSurface(hideable: Bool) -> ConversationSection {
        var section = conversation
        if hideable { section.hide = { selection.setOpensConversation(false, for: row.folder) } }
        return section
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
