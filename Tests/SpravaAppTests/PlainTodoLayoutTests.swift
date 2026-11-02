import AppKit
import BinderFormat
import Shelf
import SpravaKit
import SwiftUI
import Testing
@testable import SpravaApp

@MainActor @Suite(.serialized) struct PlainTodoLayoutTests {
    @Test func bothSurfacesAndOpenEditorsFitTheMinimumWindowWithLongInventedText() async throws {
        let f = ItemEditingTests(), (actions, runtime, folder) = try await f.binder()
        await actions.load(folder, adopted: true)
        let item = try await f.openItem("acme-1", in: folder), today = CalendarDate.today()
        let page = await f.page(folder)
        let board = TodoBoard([.init(name: "Instrument workshop with a long invented name", folder: folder, writable: true, page: page)], today: today)
        let shelfRow = await Task.detached { ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder)) }.value
        let model = TodoModel(client: runtime.client), add = TodoModel(client: runtime.client), editor = ItemEditor()
        model.details = "Keep descriptions visible.\n  More invented workshop notes."
        for editing in [false, true] {
            if editing {
                await model.edit(.init(binder: "Instrument workshop", folder: folder, item: item, bucket: .later, writable: true), editor: editor)
                editor.setStatus(.waiting, in: folder); editor.setWaitingOn("Workshop office", in: folder)
                editor.setFollowUp(today.adding(days: 3), in: folder)
            }
            for global in [true, false] {
                let surface: AnyView
                if global {
                    surface = AnyView(TodosView(model: model, editor: editor, board: board, rows: [shelfRow], open: { _ in }, reload: {}))
                } else {
                    surface = AnyView(List {
                        DirectTodoSection(model: add, target: .init(folder: folder, label: "Instrument workshop"), reload: {})
                        Section("To-dos") {
                            ItemRow(item: item, bucket: .later, actions: actions, editor: editor, folder: folder, editable: true, reload: {})
                        }
                    })
                }
                for size in [CGSize(width: 760, height: 480), CGSize(width: 1024, height: 768)] {
                    let root = NavigationSplitView {
                        List { Text("Instrument workshop") }.navigationSplitViewColumnWidth(min: 240, ideal: 240)
                    } detail: { surface }
                    .frame(minWidth: 760, minHeight: 480)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
                    let reference = NSHostingView(rootView: NavigationSplitView {
                        List { Text("Instrument workshop") }.navigationSplitViewColumnWidth(min: 240, ideal: 240)
                    } detail: { Text("Project") }.frame(minWidth: 760, minHeight: 480))
                    let referenceWindow = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    referenceWindow.contentView = reference
                    let host = NSHostingView(rootView: root)
                    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.contentView = host
                    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
                    #expect(host.fittingSize.height <= 480 && host.fittingSize.width <= 760)
                    // NavigationSplitView extends into the native titlebar safe area.
                    #expect(abs(host.bounds.width - size.width) < 2 && host.bounds.height <= window.frame.height)
                    #expect(window.frame.height <= referenceWindow.frame.height)
                    referenceWindow.orderOut(nil)
                    if let directory = ProcessInfo.processInfo.environment["SPRAVA_RENDER_ARTIFACTS_DIR"] {
                        let url = URL(fileURLWithPath: directory, isDirectory: true)
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let name = "\(global ? "todos" : "project")-\(editing ? "editing" : "rows")-\(Int(size.width))x\(Int(size.height)).png"
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(name))
                    }
                    window.orderOut(nil)
                }
            }
        }
    }
}
