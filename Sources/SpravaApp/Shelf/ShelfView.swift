import AppKit
import BinderFormat
import BinderStore
import Combine
import Services
import Shelf
import SpravaKit
import SwiftUI

// ObservableObject rather than @Observable/@State: the Command Line Tools ship no SwiftUI macro plugin.
@MainActor
final class ShelfModel: ObservableObject {
    @Published var rows: [ShelfRow] = []
    @Published var today = CalendarDate.today()
    @Published private(set) var counts: [URL: ShelfCounts] = [:]
    /// The binder opened is recorded at once (the Shelf's own UI state, `recent.json`); the Shelf reorders on its
    /// next refresh, so the row never jumps away under the pointer.
    @Published var selection: URL? {
        didSet {
            if let s = selection, s.isFileURL, s != oldValue {
                let support = support
                workQueue.async { try? RecentBinders(supportDirectory: support).touch(s) }
            }
        }
    }
    @Published private var snapshotNote: String?
    @Published private var operationNote: String?
    var note: String? {
        let parts = [operationNote, snapshotNote].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
    @Published var lastRefresh: Date?

    private let support: URL
    private let workQueue = DispatchQueue(label: "sprava.shelf.reads", qos: .utility)
    private lazy var disk = ShelfDiskWorker(queue: workQueue)
    private let readTimeout: TimeInterval
    private var snapshotGeneration: UInt64 = 0
    private let readSnapshot: @Sendable (URL) -> ShelfSnapshot.Snapshot
    private let summarize: @Sendable (ShelfRow, CalendarDate) -> ShelfCounts
    private var refreshTask: Task<Void, Never>?
    let client: RuntimeClient

    init(support: URL = SpravaPaths.supportDirectory(), client: RuntimeClient = RuntimeClient(),
         readSnapshot: @escaping @Sendable (URL) -> ShelfSnapshot.Snapshot = ShelfSnapshot.read, readTimeout: TimeInterval = 5,
         summarize: @escaping @Sendable (ShelfRow, CalendarDate) -> ShelfCounts = ShelfCounts.read) {
        self.support = support
        self.readSnapshot = readSnapshot
        self.readTimeout = readTimeout
        self.summarize = summarize
        self.client = client
    }

    /// One background read at a time, including slow or unavailable picked volumes. Existing rows stay visible.
    func refresh() {
        guard refreshTask == nil else { return }
        let support = support
        let worker = disk
        let timeout = readTimeout
        let generation = snapshotGeneration
        let read = readSnapshot
        let summarize = summarize
        refreshTask = Task { [weak self] in
            let prepared = await worker.run(timeout: timeout) {
                let snapshot = read(support)
                let today = CalendarDate.today()
                var counts: [URL: ShelfCounts] = [:]
                for row in snapshot.rows { counts[row.folder] = summarize(row, today) }
                return ShelfPresentation(snapshot: snapshot, today: today, counts: counts)
            }
            guard let self else { return }
            defer { refreshTask = nil }
            guard let prepared else {
                snapshotNote = "Some binder files are taking too long to read. The Shelf could not refresh; saved changes will appear when the files can be read."
                return
            }
            guard generation == snapshotGeneration else { return }
            today = prepared.today
            rows = prepared.snapshot.rows
            counts = prepared.counts
            snapshotNote = prepared.snapshot.note
            if selection == nil || !rows.contains(where: { $0.folder == selection }) { selection = rows.first?.folder }
            lastRefresh = Date()
        }
    }

    /// Commands await publication before attaching their result or error to the refreshed Shelf.
    func refreshAndWait(afterChanges: Bool = false) async {
        // A command must not reuse a snapshot that started before its write.
        if afterChanges, let pending = refreshTask { await pending.value }
        refresh()
        await refreshTask?.value
    }

    private func isBinder(_ url: URL) async -> Bool? {
        await disk.run(timeout: readTimeout) { Teka.read(url).state != .notATeka }
    }

    /// Re-reads every minute, so a new day or an edit made elsewhere shows without a click.
    func refreshLoop() async {
        while !Task.isCancelled {
            await refreshAndWait()
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
        let urls = panel.urls
        Task { await add(urls) }
    }

    /// Asks the runtime to add the chosen folders. What went wrong is said after the refresh, which would otherwise
    /// clear it.
    func add(_ urls: [URL]) async {
        operationNote = nil
        var skipped: [String] = []
        var failed: [String] = []
        for url in urls {
            guard let valid = await isBinder(url) else {
                failed.append("Could not check \(url.lastPathComponent): its files are still waiting to be read.")
                continue
            }
            if !valid {
                skipped.append(url.lastPathComponent)
                continue
            }
            do {
                _ = try await client.command("shelf_add", binder: url)
                snapshotGeneration &+= 1
            } catch {
                failed.append("Could not add \(url.lastPathComponent): \(error)")
            }
        }
        await refreshAndWait(afterChanges: true)
        if !skipped.isEmpty { failed.append("Not added (no catalog.json): \(skipped.joined(separator: ", "))") }
        if !failed.isEmpty { operationNote = failed.joined(separator: "\n") }
    }

    func removeFromShelf(_ row: ShelfRow) async {
        operationNote = nil
        var failure: String?
        do {
            _ = try await client.command("shelf_remove", binder: row.folder)
            snapshotGeneration &+= 1
            rows.removeAll { $0.folder == row.folder }
            if selection == row.folder { selection = rows.first?.folder }
        } catch {
            failure = "Could not remove \(row.name): \(error)"
        }
        await refreshAndWait(afterChanges: true)
        if let failure { operationNote = failure }
    }

    /// A new binder from a template (mvp.md feature 6), created by the runtime.
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
        Task { await createBinder(parent: parent, name: name, template: template, year: year) }
    }

    func createBinder(parent: URL, name: String, template: String, year: Int) async {
        operationNote = nil
        do {
            let r = try await client.global("create_binder", [("parent", .string(parent.path)), ("name", .string(name)),
                ("template", .string(template)), ("year", .int(year))])
            snapshotGeneration &+= 1
            await refreshAndWait(afterChanges: true)
            if let path = r["binder"]?.stringValue { selection = URL(fileURLWithPath: path).standardizedFileURL }
        } catch {
            operationNote = "The binder was not created: \(error)"
        }
    }

    var selectedRow: ShelfRow? { rows.first { $0.folder == selection } }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Shelf") {
                    ForEach(model.rows, id: \.folder) { row in
                        ShelfRowView(row: row, counts: model.counts[row.folder] ?? ShelfCounts())
                            .tag(row.folder)
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.folder]) }
                                if row.source == .picked {
                                    Button("Remove from Shelf") { Task { await model.removeFromShelf(row) } }
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
            if let row = model.selectedRow {
                BinderSummaryView(row: row, today: model.today, counts: model.counts[row.folder] ?? ShelfCounts())
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
        .toolbar {
            Button { model.newBinder() } label: { Label("New Binder", systemImage: "plus.rectangle.on.folder") }
            Button { model.addFolderWithPanel() } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }
}

struct ShelfRowView: View {
    let row: ShelfRow
    let counts: ShelfCounts

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name).font(.headline)
            HStack(spacing: 6) {
                StateBadge(state: row.teka.state, label: row.stateLabel)
                if counts.count(.overdue) > 0 {
                    Text("\(counts.count(.overdue)) overdue").foregroundStyle(.red)
                }
                if counts.count(.nudge) > 0 {
                    Text("\(counts.count(.nudge)) to chase").foregroundStyle(.orange)
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

/// One binder at a glance until its Now page arrives with the Binder screen: its level and state, and how many
/// items fall in each bucket today. Read from disk; nothing here writes.
struct BinderSummaryView: View {
    let row: ShelfRow
    let today: CalendarDate
    let counts: ShelfCounts

    var body: some View {
        let teka = row.teka
        List {
            Section {
                Text(teka.name).font(.title2.bold())
                Text("\(teka.level?.label ?? "unreadable") · \(row.stateLabel) · today \(today.description)")
                    .foregroundStyle(.secondary)
                ForEach(teka.reasons, id: \.self) { Text("• \($0)").foregroundStyle(.orange) }
            }
            Section("Today") {
                ForEach(Bucket.allCases.filter { $0 != .recentlyClosed && counts.count($0) > 0 }, id: \.self) { bucket in
                    HStack {
                        Text(bucket.title)
                        Spacer()
                        Text("\(counts.count(bucket))").foregroundStyle(.secondary)
                    }
                }
            }
        }
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
