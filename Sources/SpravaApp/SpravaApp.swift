import AppKit
import Combine
import SpravaKit
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
                Button("New Binder…") { model.newBinder() }
                    .keyboardShortcut("n")
                Button("Add Folder…") { model.addFolderWithPanel() }
                    .keyboardShortcut("o")
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
            }
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
            model.selection = pick == "health" ? healthSelection : pick == "inbox" ? inboxSelection : pick == "brains" ? brainsSelection
                : pick == "backup" ? backupSelection : model.rows.first { $0.name == pick }?.folder ?? model.selection
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
