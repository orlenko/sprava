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
    /// Asks for a new binder's template and name, for an empty folder the person picked or (nil) a folder still to choose.
    var askForBinder: @MainActor (_ empty: URL?, _ year: Int) -> (template: String, name: String)? = ShelfModel.binderAlert
    var chooseParent: @MainActor () -> URL? = ShelfModel.parentPanel
    var chooseFolders: @MainActor () -> [URL] = ShelfModel.addPanel
    /// Asked when an action finds the runtime not running: whether to turn background work on, and the turning on.
    var offerBackgroundWork: @MainActor () -> Bool = BackgroundWork.offer
    var turnOnBackgroundWork: @MainActor () -> BackgroundWork.TurnOn
    /// How long a runtime just turned on has to answer before the action gives up; launchd usually needs a few seconds.
    var startWait: Duration = .seconds(20)

    init(support: URL = SpravaPaths.supportDirectory(), client: RuntimeClient = RuntimeClient(),
         readSnapshot: @escaping @Sendable (URL) -> ShelfSnapshot.Snapshot = ShelfSnapshot.read, readTimeout: TimeInterval = 5,
         summarize: @escaping @Sendable (ShelfRow, CalendarDate) -> ShelfCounts = ShelfCounts.read) {
        self.support = support
        self.readSnapshot = readSnapshot
        self.readTimeout = readTimeout
        self.summarize = summarize
        self.client = client
        turnOnBackgroundWork = { BackgroundWork.turnOn(with: HealthModel(support: support)) }
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
            if selection == nil || (!pages.contains(selection!) && !rows.contains(where: { $0.folder == selection })) { selection = rows.first?.folder }
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

    /// Whether the folder is a binder, an empty folder that could become one, or neither; nil when it cannot be read in time.
    private func kind(of url: URL) async -> FolderKind? {
        await disk.run(timeout: readTimeout) {
            Teka.read(url).state != .notATeka ? .binder : BinderCreator.isEmptyFolder(url) ? .empty : .other
        }
    }

    private enum FolderKind: Sendable { case binder, empty, other }

    /// Re-reads every minute, so a new day or an edit made elsewhere shows without a click.
    func refreshLoop() async {
        while !Task.isCancelled {
            await refreshAndWait()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    func addFolderWithPanel() { Task { await addFolder() } }

    /// The folder panel opens only once the runtime, which adds them, is there.
    func addFolder() async {
        operationNote = nil
        guard await runtimeReady() else { return }
        let urls = chooseFolders()
        if !urls.isEmpty { await add(urls) }
    }

    /// Asks the runtime to add the chosen folders; an empty one is offered as a new binder. What went wrong is said
    /// after the refresh, which would otherwise clear it.
    func add(_ urls: [URL]) async {
        operationNote = nil
        var skipped: [String] = []
        var failed: [String] = []
        var empty: [URL] = []
        var binders: [URL] = []
        for url in urls {
            guard let kind = await kind(of: url) else {
                failed.append("Could not check \(url.lastPathComponent): its files are still waiting to be read.")
                continue
            }
            switch kind {
            case .binder: binders.append(url)
            case .empty: empty.append(url)
            case .other: skipped.append(url.lastPathComponent)
            }
        }
        if !(binders.isEmpty && empty.isEmpty), await !runtimeReady() {
            failed.insert(operationNote ?? "Nothing was added: Sprava's background part is not running.", at: 0)
            (binders, empty) = ([], [])
        }
        for url in binders {
            do {
                _ = try await client.command("shelf_add", binder: url)
                snapshotGeneration &+= 1
            } catch {
                failed.append("Could not add \(url.lastPathComponent): \(error)")
            }
        }
        await refreshAndWait(afterChanges: true)
        let year = Calendar.current.component(.year, from: Date())
        for url in empty {
            guard let answer = askForBinder(url, year) else { continue }
            if let failure = await create(parent: url.deletingLastPathComponent(), name: answer.name, template: answer.template,
                                          year: year, existing: url) {
                failed.append("\(url.lastPathComponent) did not become a binder: \(failure)")
            }
        }
        if !skipped.isEmpty {
            failed.append("Not added (no catalog.json; New Binder makes a binder): \(skipped.joined(separator: ", "))")
        }
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

    func newBinder() { Task { await startNewBinder() } }

    /// A new binder from a template (mvp.md feature 6), created by the runtime. Nothing is asked until the runtime is
    /// there, so the person never fills in dialogs that cannot succeed.
    func startNewBinder() async {
        operationNote = nil
        guard await runtimeReady() else { return }
        let year = Calendar.current.component(.year, from: Date())
        guard let answer = askForBinder(nil, year), let parent = chooseParent() else { return }
        await createBinder(parent: parent, name: answer.name, template: answer.template, year: year)
    }

    /// Whether the runtime is there for an action that needs it (`ping`, two seconds at most; one only slow to answer goes
    /// ahead). When it is not running, the person is offered to turn background work on, and the action goes ahead once the
    /// runtime answers within `startWait`; otherwise it stops before any dialog or request, and the note says why.
    func runtimeReady() async -> Bool {
        guard await client.presence() == .notRunning else { return true }
        guard offerBackgroundWork() else { return false }
        switch turnOnBackgroundWork() {
        case .failed(let why):
            operationNote = why
        case .needsApproval:
            operationNote = "Background work is waiting for your approval in System Settings › General › Login Items. Approve Sprava there, then try again."
        case .registered:
            operationNote = "Starting Sprava's background part…"
            let deadline = ContinuousClock.now + startWait
            repeat {
                if await client.presence() == .answers { operationNote = nil; return true }
                try? await Task.sleep(for: .milliseconds(500))
            } while ContinuousClock.now < deadline
            operationNote = "Background work is on, but Sprava's background part has not started yet. Try again in a minute; Health, at the top of the sidebar, shows when it is running."
        }
        return false
    }

    func createBinder(parent: URL, name: String, template: String, year: Int) async {
        operationNote = nil
        if let failure = await create(parent: parent, name: name, template: template, year: year) {
            operationNote = "The binder was not created: \(failure)"
        }
    }

    /// Asks the runtime for the binder and selects it; returns what went wrong, if anything.
    private func create(parent: URL, name: String, template: String, year: Int, existing: URL? = nil) async -> String? {
        var fields: [(String, JSONValue)] = [("parent", .string(parent.path)), ("name", .string(name)),
                                            ("template", .string(template)), ("year", .int(year))]
        if let existing { fields.append(("folder", .string(existing.path))) }
        do {
            let r = try await client.global("create_binder", fields)
            snapshotGeneration &+= 1
            await refreshAndWait(afterChanges: true)
            if let path = r["binder"]?.stringValue { selection = URL(fileURLWithPath: path).standardizedFileURL }
            return nil
        } catch {
            return "\(error)"
        }
    }

    var selectedRow: ShelfRow? { rows.first { $0.folder == selection } }

    /// The sidebar's pages above the Shelf.
    let pages: Set<URL> = [healthSelection, inboxSelection, brainsSelection]
}

let healthSelection = URL(string: "sprava:health")!
let inboxSelection = URL(string: "sprava:inbox")!
let brainsSelection = URL(string: "sprava:brains")!

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @StateObject private var inbox = InboxModel()
    @StateObject private var health = HealthModel()
    @StateObject private var brains = BrainsModel()

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
                        if inbox.cardCount > 0 { Text("\(inbox.cardCount)").foregroundStyle(.secondary) }
                    }
                    .tag(inboxSelection)
                    Label("Brains", systemImage: "brain").tag(brainsSelection)
                }
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
                    Button { model.newBinder() } label: { Label("New Binder…", systemImage: "plus") }
                        .buttonStyle(.borderless)
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
            } else if model.selection == inboxSelection {
                InboxView(model: inbox, rows: model.rows)
            } else if model.selection == brainsSelection {
                BrainsView(model: brains, rows: model.rows)
            } else if let row = model.selectedRow {
                NowView(row: row, today: model.today,
                        page: model.counts[row.folder]?.page ?? NowPage(items: [], log: [], today: model.today, timeZone: .current),
                        reload: { model.refresh() })
            } else {
                ContentUnavailableView {
                    Label("No binders yet", systemImage: "books.vertical")
                } description: {
                    Text("Start a new binder, or add a folder that already holds one.")
                } actions: {
                    Button("New Binder…") { model.newBinder() }
                        .buttonStyle(.borderedProminent)
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
        // Health is read here, not on its page, so the sidebar's dot stays current whichever page is open.
        .task {
            while !Task.isCancelled {
                health.refresh()
                try? await Task.sleep(for: .seconds(10))
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
