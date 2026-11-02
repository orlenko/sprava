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
            ConversationSection(model: $0, row: row, reload: refresh, openBrains: openBrains)
        })
    }

    var body: some View {
        let teka = row.teka
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 10)
            if let conversation, let surface = inputs.conversation {
                BinderWorkspace(model: conversation, selection: workspace, row: row,
                                conversation: surface, project: project)
            } else {
                project
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

    private var project: some View {
        let teka = row.teka
        return VStack(spacing: 0) {
            if teka.isAdopted, !teka.writesBlocked { IntakeDropBar(folder: row.folder) }
            List {
                if teka.isAdopted, !teka.writesBlocked {
                    DirectTodoSection(model: todoAdd, target: .init(folder: row.folder, label: row.name), reload: { refresh() })
                }
                if let local = inputs.note { local }
                if teka.isAdopted, !teka.writesBlocked { EmailIntakeSection(folder: row.folder) }
                ReviewSection(actions: actions, folder: row.folder, reload: refresh)
                FiledDocumentsSection(row: row, model: documents, reload: refresh)
                StrandedItemEdit(actions: actions, editor: editor, folder: row.folder, page: page, reload: refresh)
                ForEach(Bucket.allCases, id: \.self) { bucket in
                    if bucket == .recentlyClosed {
                        if !page.closed.isEmpty {
                            Section(header: BucketHeader(bucket: bucket, count: page.closed.count)) {
                                ForEach(page.closed.enumerated().map { ("closed-\($0.offset)", $0.element) }, id: \.0) { _, entry in
                                    HStack {
                                        Text(entry.closedOn?.description ?? "date unknown")
                                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                                        Text(entry.title).strikethrough(entry.action == "done")
                                        Spacer()
                                        Text(entry.action).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } else if let items = page.items[bucket], !items.isEmpty {
                        Section(header: BucketHeader(bucket: bucket, count: items.count)) {
                            // Row ids are unique across sections: List reuses rows by id, and two sections that both
                            // start at 0 would show one section's row in the other.
                            ForEach(items.map { ("item-\($0.index)", $0) }, id: \.0) { _, item in
                                ItemRow(item: item, bucket: bucket, actions: actions, editor: editor, folder: row.folder,
                                        editable: teka.isAdopted && !teka.writesBlocked, reload: refresh)
                            }
                        }
                    }
                }
                if page.hiddenCount > 0 {
                    Text("\(page.hiddenCount) dismissed item(s) hidden").foregroundStyle(.secondary)
                }
                HistorySection(actions: actions, folder: row.folder, reload: refresh)
                if teka.isAdopted {
                    AboutSection(actions: actions, folder: row.folder, today: today, reload: refresh)
                }
            }
        }
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
    var body: some View { Text("\(bucket.title) (\(count))").font(.headline) }
}
