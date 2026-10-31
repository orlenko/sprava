import AppKit
import BinderFormat
import Foundation
import Services
import Shelf
import SpravaKit
import SwiftUI
import Testing
@testable import SpravaApp

@MainActor
@Suite(.serialized) struct ConversationWorkspaceTests {
    let folder = URL(fileURLWithPath: "/invented/instrument-workshop")

    @Test func surfaceChoicesBelongToEachBinderAndDoNotOverrideAChoiceWhenConnectionChanges() {
        let selection = BinderWorkspaceSelection()
        let other = URL(fileURLWithPath: "/invented/garden")
        #expect(selection.surface(for: folder, hasConversation: true) == .conversation)
        #expect(selection.surface(for: other, hasConversation: false) == .project)
        selection.choose(.project, for: folder)
        #expect(selection.surface(for: folder, hasConversation: true) == .project)
        selection.choose(.conversation, for: other)
        #expect(selection.surface(for: other, hasConversation: false) == .conversation)
        #expect(selection.surface(for: folder, hasConversation: false) == .project)
    }

    @Test func growingRepliesDoNotPullAReaderAwayFromEarlierMessages() {
        let viewport = ConversationViewport()
        viewport.measured(atBottom: false) // Content grew before the view could follow it.
        #expect(viewport.followsLatest)
        viewport.scrolling(true)
        viewport.measured(atBottom: false)
        viewport.scrolling(false)
        viewport.measured(atBottom: false)
        #expect(!viewport.followsLatest)
        viewport.jumpToLatest()
        viewport.measured(atBottom: false)
        #expect(viewport.followsLatest)
        viewport.scrolling(true)
        viewport.measured(atBottom: false)
        viewport.measured(atBottom: true)
        #expect(viewport.followsLatest)
    }

    func fixture() async throws -> ClaudeBinderConversation {
        let scope = UUID()
        let records: [JSONValue] = (1...18).map { index in
            let reply = JSONWriter.compact(.obj([("answer", .str("Instrument \(index): record the observed condition, purchase evidence and repair costs separately.\n\nThe estimate is not a verified sale price. Keep the original source and check the missing details before drafting a reply.")),
                ("citations", .array([])), ("task", .null), ("draft", .null)]))
            return .obj([("binder_id", .str(scope.uuidString)), ("request_id", .str(UUID().uuidString)),
                ("turn_id", .str(UUID().uuidString)), ("text", .str("What should I check for instrument \(index)?\nKeep the source evidence separate from estimates.")),
                ("phase", .str("replied")), ("reply", .str(reply))])
        }
        let model = ClaudeBinderConversation(client: RuntimeClient(answer: { text in
            let request = try JSONParser.parse(text).value
            switch request["command"]?.stringValue {
            case "claude_binder": return JSONWriter.compact(.obj([("ok", .bool(true)), ("enabled", .bool(true)), ("binder_id", .str(scope.uuidString))]))
            case "chat_history": return JSONWriter.compact(.obj([("ok", .bool(true)), ("turns", .array(records))]))
            default: throw ChatCommandFailure.invalidRequest
            }
        }), authenticate: {})
        await model.show(folder)
        return model
    }

    func surface(_ model: ClaudeBinderConversation, selection: BinderWorkspaceSelection) -> some View {
        let row = ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))
        return HStack(spacing: 0) {
            List { Text("Shelf").font(.headline); Label("Instrument workshop", systemImage: "folder") }.frame(width: 240)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text("Instrument workshop").font(.title2.bold()).padding(.horizontal, 16).padding(.top, 12)
                BinderWorkspace(model: model, selection: selection, row: row,
                    conversation: ConversationSection(model: model, row: row, reload: {}),
                    project: List { Text("To-dos"); Text("Filed documents"); Text("History") })
            }
        }
    }

    func settle(_ host: NSView) async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }

    @Test func nativeTranscriptGrowsWithTheWindowAndTheComposerStaysReachable() async throws {
        let model = try await fixture()
        let selection = BinderWorkspaceSelection()
        let host = NSHostingView(rootView: surface(model, selection: selection)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        var transcriptHeights: [CGFloat] = []
        for size in [NSSize(width: 1024, height: 768), NSSize(width: 1440, height: 900), NSSize(width: 760, height: 480)] {
            window.setContentSize(size)
            await settle(host)
            let scrolls = descendants(host, of: NSScrollView.self)
            let editor = try #require(scrolls.first { $0.documentView is NSTextView })
            let transcript = try #require(scrolls.first { !($0.documentView is NSTextView) && !($0.documentView is NSTableView) })
            transcriptHeights.append(transcript.frame.height)
            #expect(host.bounds.contains(host.convert(editor.bounds, from: editor)))
            #expect(transcript.frame.height > editor.frame.height)
            if let document = transcript.documentView {
                #expect(transcript.documentVisibleRect.maxY >= document.bounds.height - 28)
            }
            if let directory = ProcessInfo.processInfo.environment["SPRAVA_RENDER_ARTIFACTS_DIR"] {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    destination.appendingPathComponent("conversation-\(Int(size.width))x\(Int(size.height)).png"))
            }
        }
        #expect(transcriptHeights[1] > transcriptHeights[0] + 100)
        model.chat.draft = DraftEditorHeightTests.long
        await settle(host)
        let editor = try #require(descendants(host, of: NSTextView.self).first?.enclosingScrollView)
        #expect(host.bounds.contains(host.convert(editor.bounds, from: editor)))
        #expect(editor.frame.height < host.bounds.height / 2)
        #expect(model.chat.draft == DraftEditorHeightTests.long)
    }

    @Test func nativeSurfaceSwitchingKeepsTheDraftAndExistingLiveReply() async throws {
        let server = ConversationResumeTests.Server()
        defer { server.finish("interrupted") }
        let model = ConversationResumeTests().model(server)
        await model.show(folder)
        model.chat.draft = "Keep this separate unsent workshop question."
        let selection = BinderWorkspaceSelection()
        let host = NSHostingView(rootView: surface(model, selection: selection)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        await settle(host)
        selection.choose(.project, for: folder)
        await settle(host)
        selection.choose(.conversation, for: folder)
        await settle(host)
        #expect(model.chat.draft == "Keep this separate unsent workshop question.")
        #expect(model.chat.isReplying && server.polls == 1)
        #expect(server.calls.allSatisfy { $0["command"] != .str("chat_send") && $0["command"] != .str("chat_stop") })
    }

    @Test func scrollingEarlierDuringAReplyPreservesTheNativeViewport() async throws {
        let backend = BinderChatTests.StandIn()
        defer { backend.end() }
        let history: [BinderChat.Entry] = (1...30).map {
            .init(id: UUID(), speaker: .binder, text: "Invented workshop reply \($0).\nKeep its evidence separate from estimates.", state: .earlier)
        }
        let chat = BinderChatTests().chat(backend, history: history)
        await chat.show(BinderChatTests.folder)
        chat.draft = "Continue the invented workshop reply."
        await chat.send()
        backend.emit(.textDelta("A live invented reply.\n"))
        let host = NSHostingView(rootView: ChatView(chat: chat).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        await settle(host)
        let scroll = try #require(descendants(host, of: NSScrollView.self).first { !($0.documentView is NSTextView) })
        let latest = scroll.documentVisibleRect.origin.y
        // Move the native clip view as a scroll-bar drag would; inject no desktop events.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, latest - 400)))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(host)
        let reading = scroll.documentVisibleRect.origin.y
        #expect(reading < latest - 100)
        backend.emit(.textDelta(String(repeating: "More invented detail arrives.\n", count: 20)))
        await settle(host)
        #expect(abs(scroll.documentVisibleRect.origin.y - reading) < 2)
    }
}
