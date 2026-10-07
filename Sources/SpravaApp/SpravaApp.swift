import AppKit
import Combine
import SpravaCore
import SwiftUI

// Increment 1 (docs/mvp.md section 5): a read-only window with the Shelf and each binder's Now page.
// Nothing here writes inside a binder; "Add Folder…" writes only Sprava's own shelf.json.

@main
struct SpravaApp: App {
    @StateObject private var model = ShelfModel()

    init() {
        // Hidden: `SpravaApp --snapshot out.png` renders the window offscreen and exits, for layout checks
        // against invented binders (point SPRAVA_SUPPORT_DIR and CMIRROR_CONFIG at a test folder).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Sprava") {
            ShelfView(model: model)
                .frame(minWidth: 760, minHeight: 480)
                .task { await model.refreshLoop() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { model.addFolderWithPanel() }
                    .keyboardShortcut("o")
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
            }
        }
    }
}

// ObservableObject rather than @Observable/@State: the Command Line Tools ship no SwiftUI macro plugin.
@MainActor
final class ShelfModel: ObservableObject {
    @Published var rows: [ShelfRow] = []
    @Published var today = CalendarDate.today()
    @Published var selection: URL?
    @Published var note: String?
    @Published var lastRefresh: Date?

    private let store = ShelfStore()

    func refresh() {
        today = CalendarDate.today()
        var registry: LifeprojRegistry?
        note = nil
        let url = LifeprojRegistry.defaultPath()
        if FileManager.default.fileExists(atPath: url.path) {
            do { registry = try LifeprojRegistry.load(from: url) } catch {
                note = "lifeproj's registry could not be read: \(error.localizedDescription)"
            }
        }
        var picked: [URL] = []
        do { picked = try store.readFolders() } catch { note = "\(error)" }
        rows = Shelf.rows(registry: registry, picked: picked)
        if selection == nil || (selection != healthSelection && !rows.contains(where: { $0.folder == selection })) {
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

    func removeFromShelf(_ row: ShelfRow) {
        do { try store.remove(row.folder) } catch { note = "Could not remove it: \(error)" }
        refresh()
    }

    var selectedRow: ShelfRow? { rows.first { $0.folder == selection } }
}

let healthSelection = URL(string: "sprava:health")!

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @StateObject private var health = HealthModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    HStack {
                        Circle().fill(health.beatGrade.color).frame(width: 9, height: 9)
                        Text("Health").font(.headline)
                    }
                    .tag(healthSelection)
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
                    Text("Read-only. Updated \(model.lastRefresh.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }
        } detail: {
            if model.selection == healthSelection {
                HealthView(model: health)
            } else if let row = model.selectedRow {
                NowView(row: row, today: model.today)
            } else {
                ContentUnavailableView {
                    Label("No binders yet", systemImage: "books.vertical")
                } description: {
                    Text("Add a binder folder with File › Add Folder…, or register it with lifeproj.")
                } actions: {
                    Button("Add Folder…") { model.addFolderWithPanel() }
                }
            }
        }
        .toolbar {
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

struct NowView: View {
    let row: ShelfRow
    let today: CalendarDate

    var body: some View {
        let teka = row.teka
        let page = teka.nowPage(today: today)
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(teka.name).font(.title2.bold())
                    Text("\(teka.level?.label ?? "unreadable") · \(row.stateLabel) · today \(today.description)")
                        .foregroundStyle(.secondary)
                    if teka.state < .needsMigration {
                        ForEach(teka.reasons, id: \.self) { Text("• \($0)").foregroundStyle(.orange) }
                    }
                    if !teka.findings.isEmpty {
                        Text("\(teka.findings.count) rule finding(s); run `sprava check` for the list.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
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
                        ForEach(items.map { ("item-\($0.index)", $0) }, id: \.0) { _, item in ItemRow(item: item, bucket: bucket) }
                    }
                }
            }
            if page.hiddenCount > 0 {
                Text("\(page.hiddenCount) dismissed item(s) hidden").foregroundStyle(.secondary)
            }
        }
    }
}

struct BucketHeader: View {
    let bucket: Bucket
    let count: Int
    var body: some View { Text("\(bucket.title) (\(count))").font(.headline) }
}

struct ItemRow: View {
    let item: Item
    let bucket: Bucket

    var dateText: String {
        if bucket == .nudge || bucket == .waiting {
            return item.followUpAt.map { "chase \($0)" } ?? "chase now"
        }
        return item.due?.description ?? ""
    }

    var details: [String] {
        var parts: [String] = []
        if let party = item.waitingOn { parts.append("waiting on \(party)") }
        if bucket == .nudge || bucket == .waiting, let due = item.due { parts.append("due \(due.description)") }
        if item.hasRecurrence { parts.append("repeats; the hub manages it for now") }
        if !item.tags.isEmpty { parts.append(item.tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: item.priority == .high ? "exclamationmark.circle.fill" : "circle")
                .foregroundStyle(item.priority == .high ? .red : .secondary)
            Text(dateText).monospacedDigit().foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if !details.isEmpty {
                    Text(details.joined(separator: "   ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
enum Snapshot {
    static func render(to url: URL) {
        _ = NSApplication.shared
        let model = ShelfModel()
        model.refresh()
        if let pick = ProcessInfo.processInfo.environment["SPRAVA_SELECT"] {
            model.selection = pick == "health" ? healthSelection : model.rows.first { $0.name == pick }?.folder ?? model.selection
        }
        if let today = ProcessInfo.processInfo.environment["SPRAVA_TODAY"].flatMap(CalendarDate.strict) {
            model.today = today
        }
        let view = ShelfView(model: model).frame(width: 1000, height: 640)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
