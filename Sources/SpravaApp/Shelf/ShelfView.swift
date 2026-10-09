import AppKit
import Combine
import Backup
import BinderFormat
import BinderStore
import Shelf
import SpravaKit
import SwiftUI

// ObservableObject rather than @Observable/@State: the Command Line Tools ship no SwiftUI macro plugin.
@MainActor
final class ShelfModel: ObservableObject {
    @Published var rows: [ShelfRow] = []
    @Published var today = CalendarDate.today()
    /// The binder opened is recorded at once; the Shelf reorders on its next refresh, so the row never jumps
    /// away under the pointer.
    @Published var selection: URL? {
        didSet {
            if let s = selection, s.isFileURL, s != oldValue { try? RecentBinders().touch(s) }
        }
    }
    @Published var note: String?
    @Published var lastRefresh: Date?

    private let store = ShelfStore()

    func refresh() {
        today = CalendarDate.today()
        var registry: LifeprojRegistry?
        note = nil
        // lifeproj's registry is on the Shelf only when the person turned it on (shelf.json "showRegistry").
        do { registry = try store.registryForShelf() } catch {
            note = "lifeproj's registry could not be read: \(error.localizedDescription)"
        }
        var picked: [URL] = []
        do { picked = try store.readFolders() } catch { note = "\(error)" }
        rows = RecentBinders.order(Shelf.rows(registry: registry, picked: picked), opened: RecentBinders().opened())
        if selection == nil || (selection != healthSelection && selection != brainsSelection && selection != inboxSelection && selection != backupSelection && !rows.contains(where: { $0.folder == selection })) {
            selection = rows.first?.folder
        }
        lastRefresh = Date()
    }

    /// Re-reads every minute, so a new day or an edit made elsewhere shows without a click.
    func refreshLoop() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    func addFolderWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Shelf"
        panel.message = "Choose binder folders (each holds a catalog.json). Sprava only reads them."
        guard panel.runModal() == .OK else { return }
        var skipped: [String] = []
        for url in panel.urls {
            if Teka.read(url).state == .notATeka {
                skipped.append(url.lastPathComponent)
                continue
            }
            do { try store.add(url) } catch { note = "Could not add \(url.lastPathComponent): \(error)" }
        }
        refresh()
        if !skipped.isEmpty { note = "Not added (no catalog.json): \(skipped.joined(separator: ", "))" }
    }

    /// A new binder from the tax-year template (mvp.md feature 6), created by the runtime.
    func newBinder() {
        let year = Calendar.current.component(.year, from: Date())
        let alert = NSAlert()
        alert.messageText = "New binder"
        alert.informativeText = "Pick a starting point and a name: lowercase letters, digits and hyphens. A template's checklist arrives as one card to approve."
        let templates = BinderTemplate.all
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 260, height: 26))
        picker.addItems(withTitles: templates.map(\.title))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = templates[0].suggestedName(year)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
        box.addSubview(picker)
        box.addSubview(field)
        alert.accessoryView = box
        alert.addButton(withTitle: "Choose Where…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Create Here"
        panel.message = "Choose the folder that will hold the new binder."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let name = field.stringValue
        let template = templates[max(0, picker.indexOfSelectedItem)].key
        Task {
            do {
                let r = try await RuntimeClient().global("create_binder", [("parent", .string(parent.path)), ("name", .string(name)),
                                                                            ("template", .string(template)), ("year", .int(year))])
                refresh()
                if let path = r["binder"]?.stringValue { selection = URL(fileURLWithPath: path).standardizedFileURL }
            } catch {
                note = "The binder was not created: \(error)"
            }
        }
    }

    func removeFromShelf(_ row: ShelfRow) {
        do { try store.remove(row.folder) } catch { note = "Could not remove it: \(error)" }
        refresh()
    }

    var selectedRow: ShelfRow? { rows.first { $0.folder == selection } }
}

let healthSelection = URL(string: "sprava:health")!
let brainsSelection = URL(string: "sprava:brains")!
let inboxSelection = URL(string: "sprava:inbox")!
let backupSelection = URL(string: "sprava:backup")!

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @StateObject private var health = HealthModel()
    @StateObject private var brains = BrainsModel()
    @StateObject private var inbox = InboxModel()
    @StateObject private var backup = BackupModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    HStack {
                        Circle().fill(health.beatGrade.color).frame(width: 9, height: 9)
                        Text("Health").font(.headline)
                    }
                    .tag(healthSelection)
                    HStack {
                        Label("Inbox", systemImage: "tray")
                        Spacer()
                        if !inbox.cards.isEmpty { Text("\(inbox.cards.count)").foregroundStyle(.secondary) }
                    }
                    .tag(inboxSelection)
                    Label("Brains", systemImage: "brain").tag(brainsSelection)
                    Label("Backup", systemImage: "externaldrive.badge.icloud").tag(backupSelection)
                }
                Section("Shelf") {
                    ForEach(model.rows, id: \.folder) { row in
                        ShelfRowView(row: row, today: model.today)
                            .tag(row.folder)
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.folder]) }
                                if row.source == .picked {
                                    Button("Remove from Shelf") { model.removeFromShelf(row) }
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if let note = model.note {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                    Text("Updated \(model.lastRefresh.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }
        } detail: {
            if model.selection == healthSelection {
                HealthView(model: health)
            } else if model.selection == backupSelection {
                BackupView(model: backup)
            } else if model.selection == inboxSelection {
                InboxView(model: inbox, rows: model.rows)
            } else if model.selection == brainsSelection {
                BrainsView(model: brains, rows: model.rows)
            } else if let row = model.selectedRow {
                NowView(row: row, today: model.today, backup: backup, reload: { model.refresh() })
            } else {
                ContentUnavailableView {
                    Label("No binders yet", systemImage: "books.vertical")
                } description: {
                    Text("Create one with New Binder, or add an existing folder with File › Add Folder….")
                } actions: {
                    Button("Add Folder…") { model.addFolderWithPanel() }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await inbox.load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .toolbar {
            Button { model.newBinder() } label: { Label("New Binder", systemImage: "plus.rectangle.on.folder") }
            Button { model.addFolderWithPanel() } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }
}

struct ShelfRowView: View {
    let row: ShelfRow
    let today: CalendarDate

    var body: some View {
        let page = row.teka.nowPage(today: today)
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name).font(.headline)
            HStack(spacing: 6) {
                StateBadge(state: row.teka.state, label: row.stateLabel)
                if page.count(.overdue) > 0 {
                    Text("\(page.count(.overdue)) overdue").foregroundStyle(.red)
                }
                if page.count(.nudge) > 0 {
                    Text("\(page.count(.nudge)) to chase").foregroundStyle(.orange)
                }
                if let modified = row.teka.modified {
                    Text(modified, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

struct StateBadge: View {
    let state: TekaState
    let label: String

    var color: Color {
        switch state {
        case .ready: .green
        case .needsMigration: .blue
        case .needsAttention, .unknownLevel: .orange
        case .corrupt, .notATeka: .red
        }
    }

    var body: some View {
        Text(label)
            .padding(.horizontal, 5)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
