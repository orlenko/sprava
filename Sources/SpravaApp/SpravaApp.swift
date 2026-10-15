import AppKit
import Combine
import SpravaKit
import SwiftUI

// The app (architecture 2.1): it reads binders from disk to show them, through the read-only facades, and sends
// every change to the runtime (RuntimeClient). Screens arrive one folder at a time (docs/code-structure.md rule 5).

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
                // Background work is not optional (decisions.md A19): at launch the app has the runtime running,
                // without a prompt, and a request that finds it not running starts it the same way.
                .task {
                    let keeper = model.health.keeper
                    RuntimeClient.whenNotRunning = { Task { _ = await keeper.ensureRunning() } }
                    _ = await keeper.ensureRunning()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                // ⌘N stays with the WindowGroup's New Window; the table in MenuCommands.swift keeps them apart.
                Button(MenuCommand.newBinder.title) { model.newBinder() }
                    .menuShortcut(.newBinder)
                Button(MenuCommand.addFolder.title) { model.addFolderWithPanel() }
                    .menuShortcut(.addFolder)
                Button(MenuCommand.refresh.title) { model.refresh() }
                    .menuShortcut(.refresh)
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
            model.selection = pick == "health" ? healthSelection : pick == "todos" ? todosSelection : pick == "inbox" ? inboxSelection : pick == "brains" ? brainsSelection : model.rows.first { $0.name == pick }?.folder ?? model.selection
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
