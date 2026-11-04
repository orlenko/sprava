import AppKit
import Combine
import BinderFormat
import Shelf
import SpravaKit
import SwiftUI

struct NowView: View {
    let row: ShelfRow
    let today: CalendarDate
    /// Prepared with the Shelf's snapshot by its disk worker; the main actor never buckets or sorts a catalog.
    let page: NowPage
    let reload: () -> Void
    /// The runtime's state, for the line that says when changes cannot be made.
    var health: HealthModel?
    /// The note box's model, kept by the Shelf window: this page goes away while another page is open, and the
    /// drafts typed into each binder's box must outlive it.
    @ObservedObject var note: BinderNote
    /// Every binder on the Shelf, so the note box can tell when another adopted binder shares this one's name.
    var rows: [ShelfRow] = []
    /// The item being edited in place in each binder, if any. Owned by the window, so a visit to another page
    /// leaves what was typed for the person's return.
    @ObservedObject var editor: ItemEditor
    var conversation: ClaudeBinderConversation? = nil
    /// Shows the Brains page, for the conversation's one-time setup.
    var openBrains: () -> Void = {}
    @ObservedObject var actions = BinderActions()
    @ObservedObject var documents = FiledDocuments()
    @ObservedObject var todoAdd = TodoModel()
    @ObservedObject var workspace = BinderWorkspaceSelection()
    /// Makes the model behind the email intake notice; a test hands in one with a stand-in runtime.
    var emailIntake: () -> EmailIntakeModel = { EmailIntakeModel() }
    @State private var wideTodos = false

    private var showsSettings: Bool { row.teka.isAdopted && workspace.showsSettings(row.folder) }

    var sharesName: Bool {
        rows.filter { $0.teka.isAdopted && InboxView.fold($0.name) == InboxView.fold(row.name) }.count > 1
    }

    func refresh() {
        reload()
        // Adoption state comes from the Shelf's snapshot, never a read on the main actor; when the refresh shows
        // the binder adopted, the page's task below starts again with it.
        Task { await actions.load(row.folder, adopted: row.teka.isAdopted) }
    }

    var inputs: BinderInputs {
        let local: NoteBox? = row.teka.isAdopted && !row.teka.writesBlocked
            ? NoteBox(note: note, row: row, sharesName: sharesName) {
                let folder = row.folder
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await actions.loadReview(folder)
                }
            } : nil
        return BinderInputs(note: local, conversation: conversation.map {
            ConversationSection(model: $0, row: row, reload: refresh, openBrains: openBrains, restartBackground: { health?.restart() })
        })
    }

    var body: some View {
        let teka = row.teka
        IntakeDropSurface(folder: row.folder, enabled: teka.isAdopted && !teka.writesBlocked) {
            VStack(spacing: 0) {
                header.padding(.horizontal, 16).padding(.top, 10)
                BinderPageLayers(settingsShown: showsSettings) {
                    if let conversation, let surface = inputs.conversation {
                        BinderWorkspace(model: conversation, selection: workspace, row: row,
                                        conversation: surface, project: project)
                    } else {
                        project
                    }
                } settings: {
                    if teka.isAdopted {
                        BinderSettingsPage(actions: actions, folder: row.folder, today: today, writable: !teka.writesBlocked,
                                           conversation: conversation, reload: refresh)
                    }
                }
            }
        }
        .task(id: NowTask(folder: row.folder, adopted: teka.isAdopted)) {
            note.show(row.folder)
            await actions.load(row.folder, adopted: teka.isAdopted)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                if teka.isAdopted { await actions.loadReview(row.folder) }
            }
        }
    }

    private var header: some View {
        let teka = row.teka
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(teka.name).font(.title2.bold())
                Spacer()
                if teka.isAdopted {
                    if showsSettings {
                        Button("Done") { workspace.toggleSettings(row.folder) }.keyboardShortcut(.cancelAction)
                    } else {
                        Button { workspace.toggleSettings(row.folder) } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.borderless)
                            .help("This binder's settings")
                            .accessibilityLabel("This binder's settings")
                    }
                }
                if !teka.isAdopted, teka.state >= .needsMigration {
                    Button("Adopt…") { actions.adopt(row.folder, inRegistry: row.source == .registry, reload: refresh) }
                        .disabled(actions.busy)
                }
            }
            if let message = actions.message { Text(message).foregroundStyle(.orange) }
            Text("\(teka.level?.label ?? "unreadable") · \(row.stateLabel) · today \(today.description)")
                .foregroundStyle(.secondary)
            if teka.state < .needsMigration {
                ForEach(DisplayLine.rows(teka.reasons)) { Text("• \($0.text)").foregroundStyle(.orange) }
            }
            if !teka.findings.isEmpty {
                Text("\(teka.findings.count) rule finding(s); run `sprava check` for the list.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// To-dos, Explore and History, one at a time under a segmented control (issue #593). The choice is the window's, so a
    /// reload, a poll, an edit or the conversation beside it never resets it.
    var project: some View {
        VStack(spacing: 0) {
            notices
            // The cards wait on To-dos only, so its segment counts them from every tab.
            BinderPageTabs(selection: $workspace.pageTab, cards: actions.cards.count)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
            switch workspace.pageTab {
            case .todos: List { todos }
            case .explore: List { FiledDocumentsSection(row: row, model: documents, reload: refresh) }
            case .history:
                List {
                    HistorySection(actions: actions, folder: row.folder, reload: refresh)
                    if let line = Self.historyLine(actions.historyRead, empty: actions.history.isEmpty) {
                        Text(line).foregroundStyle(actions.historyRead == .failed ? .orange : .secondary)
                    }
                }
            }
        }
        .measuringTodoWidth($wideTodos)
    }

    /// What History says besides its list: nothing until a read has finished, and a failed read is never shown as no changes.
    static func historyLine(_ read: BinderActions.HistoryRead, empty: Bool) -> String? {
        switch read {
        case .reading: empty ? "Reading recent changes\u{2026}" : nil
        case .read: empty ? "No recent changes in this binder." : nil
        case .failed: "Recent changes could not be read just now. Sprava tries again in a moment."
        }
    }

    /// What must not wait for a visit to To-dos: above the tabs, so it shows on every one.
    private var notices: some View {
        let teka = row.teka
        return VStack(alignment: .leading, spacing: 6) {
            if teka.isAdopted, !teka.writesBlocked {
                EmailIntakeAttention(folder: row.folder, model: emailIntake()) {
                    if !workspace.showsSettings(row.folder) { workspace.toggleSettings(row.folder) }
                }
            }
            StrandedItemEdit(actions: actions, editor: editor, folder: row.folder, page: page, reload: refresh)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var todos: some View {
        let teka = row.teka
        if teka.isAdopted, !teka.writesBlocked {
            DirectTodoSection(model: todoAdd, target: .init(folder: row.folder, label: row.name), reload: { refresh() })
        }
        // The box for lines to review is gone from this page, which adds to-dos in its top row; a draft already typed
        // into it stays in sight until it is sent or cleared.
        if !note.text.isEmpty, let local = inputs.note { local }
        ReviewSection(actions: actions, folder: row.folder, reload: refresh)
        ForEach(Bucket.allCases, id: \.self) { bucket in
            if bucket == .recentlyClosed {
                if !page.closed.isEmpty {
                    Section(header: BucketHeader(bucket: bucket, count: page.closed.count)) {
                        ForEach(page.closed.enumerated().map { ("closed-\($0.offset)", $0.element) }, id: \.0) { _, entry in
                            ClosedTodoRow(entry: entry)
                        }
                    }
                }
            } else if let items = page.items[bucket], !items.isEmpty {
                Section(header: BucketHeader(bucket: bucket, count: items.count)) {
                    // Row ids are unique across sections: List reuses rows by id, and two sections that both
                    // start at 0 would show one section's row in the other.
                    ForEach(items.map { ("item-\($0.index)", $0) }, id: \.0) { _, item in
                        ItemRow(item: item, bucket: bucket, actions: actions, editor: editor, folder: row.folder,
                                editable: teka.isAdopted && !teka.writesBlocked, today: today, reload: refresh)
                    }
                }
            }
        }
        if page.hiddenCount > 0 {
            Text("\(page.hiddenCount) dismissed item(s) hidden").foregroundStyle(.secondary)
        }
    }
}

/// Which part of a binder's page shows: a native segmented control, reached with Tab and read by VoiceOver as one choice.
/// To-dos says how many cards wait there, so a card that arrives while another tab shows is not missed.
struct BinderPageTabs: View {
    @Binding var selection: BinderWorkspaceSelection.PageTab
    /// The cards waiting for a decision on To-dos.
    var cards = 0

    static func title(_ tab: BinderWorkspaceSelection.PageTab, cards: Int) -> String {
        tab == .todos && cards > 0 ? "\(tab.rawValue) \u{00B7} \(cards)" : tab.rawValue
    }

    static func spoken(_ tab: BinderWorkspaceSelection.PageTab, cards: Int) -> String {
        tab == .todos && cards > 0 ? "\(tab.rawValue), \(cards) \(cards == 1 ? "card" : "cards") waiting" : tab.rawValue
    }

    var body: some View {
        Picker("Show", selection: $selection) {
            ForEach(BinderWorkspaceSelection.PageTab.allCases, id: \.self) {
                Text(Self.title($0, cards: cards)).accessibilityLabel(Self.spoken($0, cards: cards)).tag($0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Binder page section")
        // Also said of the whole control, in case a segment's own label is not passed on to VoiceOver.
        .accessibilityHint(cards > 0 ? Self.spoken(.todos, cards: cards) : "")
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
    }
}

/// A to-do closed in the last days, paler than the open ones above it: smaller type in the secondary label colour, still
/// readable, and beside that, so colour is never the only sign, the line through a done one and the word for how it closed.
struct ClosedTodoRow: View {
    let entry: ClosedEntry
    static let font = Font.callout

    var body: some View {
        HStack {
            Text(entry.closedOn?.description ?? "date unknown")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(entry.title).strikethrough(entry.action == "done").foregroundStyle(.secondary)
            Spacer()
            Text(entry.action).foregroundStyle(.secondary)
        }
        .font(Self.font)
    }
}

/// What the page's task depends on: another binder, or this one once adopted, starts it again.
private struct NowTask: Hashable {
    let folder: URL
    let adopted: Bool
}

struct BucketHeader: View {
    let bucket: Bucket
    let count: Int
    var body: some View { TodoGroupHeading(title: bucket.title, count: count, bucket: bucket) }
}
