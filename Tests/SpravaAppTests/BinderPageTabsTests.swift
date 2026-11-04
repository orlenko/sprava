import AppKit
import BinderFormat
import Foundation
import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import SwiftUI
import Testing
@testable import SpravaApp

/// Issue #593: a binder's page shows To-dos, Explore or History, one at a time. The choice is the window's, so reloads,
/// polls, edits and other binders keep it; each tab holds its own controls; Recently closed reads paler than open to-dos.
/// Invented binders and stand-in runtimes only.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct BinderPageTabsTests {
    final class Shown: ObservableObject {
        @Published var row: ShelfRow
        @Published var page: NowPage
        init(row: ShelfRow, page: NowPage) { self.row = row; self.page = page }
    }

    /// The page as the Shelf builds it, with the models the window keeps; a change to `shown` is a Shelf reload.
    struct Page: View {
        @ObservedObject var shown: Shown
        let note: BinderNote, editor: ItemEditor, actions: BinderActions, documents: FiledDocuments, add: TodoModel
        let workspace: BinderWorkspaceSelection
        var conversation: ClaudeBinderConversation?
        let emailIntake: () -> EmailIntakeModel
        var now: NowView {
            NowView(row: shown.row, today: CalendarDate.today(), page: shown.page, reload: {}, note: note, editor: editor,
                    conversation: conversation, actions: actions, documents: documents, todoAdd: add, workspace: workspace,
                    emailIntake: emailIntake)
        }
        var body: some View { now }
    }

    struct Fixture {
        let page: Page
        let shown: Shown
        let actions: BinderActions
        let workspace: BinderWorkspaceSelection
        let folder: URL
        let runtime: StandInRuntime
    }

    /// An adopted binder with one open to-do, one closed (so Recently closed and an Undo show) and the fixture's filed documents.
    func fixture(conversation: Bool = false) async throws -> Fixture {
        let f = ItemEditingTests(), (actions, runtime, folder) = try await f.binder()
        await actions.load(folder, adopted: true)
        let call = try await f.openItem("acme-2", in: folder)
        try await #require(actions.close(call, as: "complete", folder, reload: {})).value
        await actions.loadReview(folder)
        let shown = Shown(row: await Self.row(folder), page: await f.page(folder))
        let workspace = BinderWorkspaceSelection()
        var talk: ClaudeBinderConversation?
        if conversation {
            talk = await Self.conversation(folder)
            workspace.setOpensConversation(true, for: folder)
        }
        let page = Page(shown: shown, note: BinderNote(client: runtime.client, support: try temporaryFolder()), editor: ItemEditor(),
                        actions: actions, documents: FiledDocuments(client: runtime.client), add: TodoModel(client: runtime.client),
                        workspace: workspace, conversation: talk,
                        emailIntake: { EmailIntakeModel(client: runtime.client, authenticate: {}) })
        return Fixture(page: page, shown: shown, actions: actions, workspace: workspace, folder: folder, runtime: runtime)
    }

    static func row(_ folder: URL) async -> ShelfRow {
        await Task.detached { ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder)) }.value
    }

    /// A connected conversation with two invented turns, so the page lays out with the conversation beside Project.
    static func conversation(_ folder: URL) async -> ClaudeBinderConversation {
        let scope = UUID().uuidString
        let turns: [JSONValue] = [("Which quote is the newest?", "The Acme quote from October is the newest one filed."),
                                  ("Is the invoice sent?", "Not yet; it is the open to-do on the right.")].map { text, answer in
            .obj([("binder_id", .str(scope)), ("request_id", .str(UUID().uuidString)), ("turn_id", .str(UUID().uuidString)),
                  ("text", .str(text)), ("phase", .str("replied")),
                  ("reply", .str(JSONWriter.compact(.obj([("answer", .str(answer)), ("citations", .array([])), ("task", .null), ("draft", .null)]))))])
        }
        let model = ClaudeBinderConversation(client: RuntimeClient(answer: { text in
            let request = try JSONParser.parse(text).value
            var fields: [(String, JSONValue)] = [("ok", .bool(true))]
            switch request["command"]?.stringValue {
            case "claude_binder": fields += [("enabled", .bool(true)), ("binder_id", .str(scope))]
            case "claude_status": fields += [("enabled", .bool(true))]
            case "chat_history": fields += [("turns", .array(turns))]
            default: throw ChatCommandFailure.invalidRequest
            }
            return JSONWriter.compact(.obj(fields))
        }), authenticate: {})
        await model.show(folder)
        return model
    }

    func host(_ view: some View, _ size: NSSize, _ scheme: ColorScheme = .light) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        return (window, host)
    }

    func settle(_ host: NSView) async {
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// The parts Project shows now, by type name, walked through its values: a branch not taken is not a value, so what
    /// another tab would show never counts. Models and the parts themselves are not walked into.
    static let parts = ["EmailIntakeAttention", "BinderPageTabs", "DirectTodoSection", "ReviewSection", "StrandedItemEdit", "ForEach<Array<Bucket>",
                        "FiledDocumentsSection", "HistorySection"]
    func shown(_ value: Any, depth: Int = 0) -> [String] {
        let name = String(describing: type(of: value))
        if let part = Self.parts.first(where: name.hasPrefix) { return [part == "ForEach<Array<Bucket>" ? name : part] }
        let mirror = Mirror(reflecting: value)
        guard depth < 40, mirror.displayStyle != .class else { return [] }
        return mirror.children.flatMap { shown($0.value, depth: depth + 1) }
    }

    func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }

    /// The tab control as drawn: its segments' names, and which one is selected.
    func tabs(_ host: NSView) throws -> (names: [String], selected: Int) {
        let control = try #require(descendants(host, of: NSSegmentedControl.self).first)
        return ((0..<control.segmentCount).compactMap { control.label(forSegment: $0) }, control.selectedSegment)
    }

    func fields(_ host: NSView) -> [String] {
        descendants(host, of: NSTextField.self).flatMap { [$0.placeholderString ?? "", $0.accessibilityLabel() ?? ""] }.filter { !$0.isEmpty }
    }

    @Test func thePageOpensAtToDosAndOpeningCardsReturnsThere() {
        let workspace = BinderWorkspaceSelection()
        #expect(workspace.pageTab == .todos)
        #expect(BinderWorkspaceSelection.PageTab.allCases.map(\.rawValue) == ["To-dos", "Explore", "History"])
        workspace.pageTab = .history
        // Cards are on the To-dos tab: a card opened from Today must not land on a tab that hides it.
        workspace.showCards(in: URL(fileURLWithPath: "/invented/kitchen-reno"))
        #expect(workspace.pageTab == .todos)
    }

    @Test func eachTabHoldsItsOwnControls() async throws {
        let f = try await fixture()
        #expect(f.workspace.pageTab == .todos)
        var parts = shown(f.page.now.project)
        // The password notice and an edit left without its row stand above the tabs, on every one.
        let above = ["EmailIntakeAttention", "StrandedItemEdit", "BinderPageTabs"]
        #expect(parts.prefix(5) == ArraySlice(above + ["DirectTodoSection", "ReviewSection"]))
        // The open to-dos with their controls, then Recently closed, in the paler row.
        let buckets = try #require(parts.first { $0.hasPrefix("ForEach<Array<Bucket>") })
        #expect(buckets.contains("ItemRow") && buckets.contains("ClosedTodoRow"))
        #expect(!parts.contains("FiledDocumentsSection") && !parts.contains("HistorySection"))

        f.workspace.pageTab = .explore
        parts = shown(f.page.now.project)
        #expect(parts == above + ["FiledDocumentsSection"])

        f.workspace.pageTab = .history
        parts = shown(f.page.now.project)
        #expect(parts == above + ["HistorySection"])
        #expect(f.actions.history.first?.undoable == true)
    }

    @Test func theChoiceOutlivesReloadsPollsEditsAndOtherBinders() async throws {
        let f = try await fixture()
        let (window, host) = host(f.page, NSSize(width: 900, height: 900))
        defer { window.orderOut(nil) }
        await settle(host)
        #expect(try tabs(host) == (["To-dos", "Explore", "History"], 0))
        #expect(!fields(host).contains("Find a document by title or path"))

        f.workspace.pageTab = .explore
        await settle(host)
        #expect(try tabs(host).selected == 1)
        #expect(fields(host).contains("Find a document by title or path"))

        // A Shelf reload, a poll of the cards and an edit opened and put back leave the tab alone.
        f.shown.page = await ItemEditingTests().page(f.folder)
        f.shown.row = await Self.row(f.folder)
        await f.actions.loadReview(f.folder)
        await f.actions.load(f.folder, adopted: true)
        let editor = f.page.editor, invoice = try await ItemEditingTests().openItem("acme-1", in: f.folder)
        #expect(editor.begin(invoice, in: f.folder, f.actions, reload: {}))
        #expect(editor.cancel(in: f.folder))
        await settle(host)
        #expect(try tabs(host).selected == 1)
        #expect(f.workspace.pageTab == .explore && fields(host).contains("Find a document by title or path"))

        // Another binder keeps the window's choice, and so does coming back.
        let other = try temporaryFolder()
        f.shown.row = await Self.row(other)
        await settle(host)
        #expect(try tabs(host).selected == 1)
        #expect(f.workspace.pageTab == .explore)
        f.shown.row = await Self.row(f.folder)
        await settle(host)
        #expect(f.workspace.pageTab == .explore && fields(host).contains("Find a document by title or path"))

        // Picking a segment is the window's choice.
        let control = try #require(descendants(host, of: NSSegmentedControl.self).first)
        control.selectedSegment = 2
        _ = control.sendAction(control.action, to: control.target)
        await settle(host)
        #expect(f.workspace.pageTab == .history && !fields(host).contains("Find a document by title or path"))
    }

    /// Paler in both appearances: the closed row's text sits nearer the background than an open title's, on average over its
    /// ink, and its type is smaller, so the difference is not carried by colour alone.
    @Test func recentlyClosedReadsPalerThanAnOpenToDo() async throws {
        let f = try await fixture()
        let entry = try #require(f.shown.page.closed.first)
        #expect(ClosedTodoRow.font == .callout)
        for scheme in [ColorScheme.light, .dark] {
            func contrast(_ view: some View) async throws -> CGFloat {
                let (window, host) = host(view.frame(width: 420, height: 28).padding(8), NSSize(width: 436, height: 44), scheme)
                defer { window.orderOut(nil) }
                await settle(host)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                func luminance(_ x: Int, _ y: Int) -> CGFloat? {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
                    return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                }
                let background = try #require(luminance(1, 1))
                var total: CGFloat = 0, ink = 0
                for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh {
                    guard let value = luminance(x, y), abs(value - background) > 0.05 else { continue }
                    total += abs(value - background); ink += 1
                } }
                return ink == 0 ? 0 : total / CGFloat(ink)
            }
            let closed = try await contrast(ClosedTodoRow(entry: entry))
            let open = try await contrast(HStack { Text(entry.title); Spacer() })
            #expect(closed > 0.05 && closed < open * 0.8, "\(scheme): closed \(closed), open \(open)")
        }
    }

    /// Email intake waiting for its password is said on every tab, not only on To-dos, where the person may not go all day.
    @Test func thePasswordNoticeShowsOnExploreAndHistory() async throws {
        let f = try await fixture()
        f.runtime.answers["imap_status"] = { _ in #"{"ok":true,"installed":true,"enabled":true,"needs_password":true}"# }
        var made: [EmailIntakeModel] = []
        let page = Page(shown: f.shown, note: f.page.note, editor: f.page.editor, actions: f.actions, documents: f.page.documents,
                        add: f.page.add, workspace: f.workspace, emailIntake: {
            let model = EmailIntakeModel(client: f.runtime.client, authenticate: {})
            made.append(model)
            return model
        })
        for tab in [BinderWorkspaceSelection.PageTab.explore, .history] {
            f.workspace.pageTab = tab
            #expect(shown(page.now.project).first == "EmailIntakeAttention")
            made = []
            let (window, host) = host(page, NSSize(width: 900, height: 700))
            await settle(host)
            // Its model was made and read by the notice drawn on this tab, and it asks for the password.
            let model = try #require(made.first)
            #expect(model.status.enabled && model.status.needsPassword)
            if let directory = ProcessInfo.processInfo.environment["SPRAVA_RENDER_ARTIFACTS_DIR"] {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    destination.appendingPathComponent("binder-tab-\(tab == .explore ? "explore" : "history")-password-light.png"))
            }
            window.orderOut(nil)
        }
    }

    /// History says it has no changes only once a read finished with none: not while reading, and not when the read failed.
    @Test func historySaysNoChangesOnlyAfterAReadFoundNone() async throws {
        #expect(NowView.historyLine(.reading, empty: true) == "Reading recent changes\u{2026}")
        #expect(NowView.historyLine(.reading, empty: false) == nil)
        #expect(NowView.historyLine(.read, empty: true) == "No recent changes in this binder.")
        #expect(NowView.historyLine(.read, empty: false) == nil)
        #expect(NowView.historyLine(.failed, empty: true)?.contains("could not be read") == true)
        #expect(NowView.historyLine(.failed, empty: false)?.contains("could not be read") == true)

        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[]}"# }
        let actions = BinderActions(client: runtime.client)
        #expect(actions.historyRead == .reading)
        // No history answer: the read fails, and the list is not taken for empty.
        await actions.load(URL(fileURLWithPath: "/Invented/kitchen-reno"), adopted: true)
        #expect(actions.historyRead == .failed && actions.history.isEmpty)
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        await actions.loadReview(URL(fileURLWithPath: "/Invented/kitchen-reno"))
        #expect(actions.historyRead == .read && actions.history.isEmpty)
        // Another binder starts unread again.
        runtime.answers["history"] = nil
        await actions.load(URL(fileURLWithPath: "/Invented/garden-shed"), adopted: true)
        #expect(actions.historyRead == .failed)
    }

    /// To-dos counts the cards waiting there, short enough for the control beside the conversation; nothing when none wait.
    @Test func toDosSaysHowManyCardsWait() {
        #expect(BinderPageTabs.title(.todos, cards: 0) == "To-dos" && BinderPageTabs.spoken(.todos, cards: 0) == "To-dos")
        #expect(BinderPageTabs.title(.todos, cards: 1) == "To-dos \u{00B7} 1")
        #expect(BinderPageTabs.spoken(.todos, cards: 1) == "To-dos, 1 card waiting")
        #expect(BinderPageTabs.title(.todos, cards: 12) == "To-dos \u{00B7} 12")
        #expect(BinderPageTabs.spoken(.todos, cards: 12) == "To-dos, 12 cards waiting")
        for tab in [BinderWorkspaceSelection.PageTab.explore, .history] {
            #expect(BinderPageTabs.title(tab, cards: 3) == tab.rawValue && BinderPageTabs.spoken(tab, cards: 3) == tab.rawValue)
        }
    }

    /// Each tab beside the conversation, light and dark, with two cards waiting on To-dos: its segment counts them from every
    /// tab. With SPRAVA_RENDER_ARTIFACTS_DIR set, it saves what it drew.
    @Test func eachTabLaysOutBesideTheConversation() async throws {
        let f = try await fixture(conversation: true)
        f.runtime.answers["proposals"] = { _ in
            #"{"ok":true,"proposals":[{"id":"p-1","state":"proposed","title":"File acme-quote.pdf","digest":"d1","verified":true},{"id":"p-2","state":"proposed","title":"File acme-receipt.pdf","digest":"d2","verified":true}]}"#
        }
        await f.actions.loadReview(f.folder)
        #expect(f.actions.cards.count == 2)
        for scheme in [ColorScheme.light, .dark] {
            for (index, tab) in BinderWorkspaceSelection.PageTab.allCases.enumerated() {
                f.workspace.pageTab = tab
                let (window, host) = host(f.page, NSSize(width: 1100, height: 720), scheme)
                await settle(host)
                #expect(host.fittingSize.height <= 720)
                // The tab control is in the window, above Project's list and clear of the conversation's column.
                let control = try #require(descendants(host, of: NSSegmentedControl.self).first)
                let frame = host.convert(control.bounds, from: control)
                #expect(host.bounds.contains(frame) && frame.minX >= host.bounds.width / 2 - 10)
                #expect(control.selectedSegment == index)
                #expect(control.label(forSegment: 0) == "To-dos \u{00B7} 2")
                // Each segment is drawn whole: none narrower than its label needs.
                for segment in 0..<control.segmentCount {
                    let label = NSAttributedString(string: control.label(forSegment: segment) ?? "", attributes: [.font: control.font as Any])
                    let width = control.width(forSegment: segment)
                    #expect(width == 0 || width >= label.size().width)
                }
                if let directory = ProcessInfo.processInfo.environment["SPRAVA_RENDER_ARTIFACTS_DIR"] {
                    let destination = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = "binder-tab-\(["todos", "explore", "history"][index])-\(scheme == .dark ? "dark" : "light").png"
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name))
                }
                window.orderOut(nil)
            }
        }
    }
}
