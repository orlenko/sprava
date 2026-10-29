import AppKit
import BinderFormat
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
@testable import SpravaApp
import SwiftUI
import Testing

/// A long text pasted into "Tell this binder" grew the box to the text's full height, taller than the window, so the
/// box ran past the page's top and bottom and could be neither read nor scrolled (2026-10-28). The box stops growing
/// at `DraftEditor.maxHeight` and scrolls inside. Invented text only.
@MainActor
@Suite struct DraftEditorHeightTests {
    static let long = (1...400).map { "Invented line \($0) about the kitchen renovation budget" }.joined(separator: "\n")

    /// The box's height as AppKit draws it: the scroll view around the text view.
    func editorHeight<Content: View>(_ content: Content) -> CGFloat? {
        let host = NSHostingView(rootView: content.frame(width: 800, height: 640))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 640), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(host)?.enclosingScrollView?.frame.height
    }

    @Test func aLongNoteScrollsInsideTheBoxAndAShortOneKeepsItSmall() throws {
        let folder = try temporaryFolder()
        let note = BinderNote(client: StandInRuntime().client, support: try temporaryFolder())
        let row = ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))
        func height() throws -> CGFloat { try #require(editorHeight(List { NoteBox(note: note, row: row, sharesName: false, added: {}) })) }
        note.text = Self.long
        #expect(try height() <= DraftEditor.maxHeight)
        note.text = "Call the invented plumber"
        #expect(try height() < DraftEditor.maxHeight / 2)
    }

    @Test func aLongMessageScrollsInsideTheComposer() async throws {
        let chat = BinderChat(commands: nil, binderID: { _ in "acme-binder" }, readHistory: { _ in ([], nil) })
        await chat.show(try temporaryFolder())
        chat.draft = Self.long
        let height = try #require(editorHeight(List { ChatView(chat: chat) }))
        #expect(height <= DraftEditor.maxHeight)
    }
}

/// The border drawn around the box must not take the clicks meant for the text inside it.
@MainActor
@Suite struct DraftEditorClickTests {
    @Test func aClickInsideTheBorderReachesTheText() async throws {
        let host = NSHostingView(rootView: DraftEditor(text: .constant("Invented line")).frame(width: 400, height: 120))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
        func find(_ view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let text = try #require(find(host))
        let scroll = try #require(text.enclosingScrollView)
        let center = host.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), from: scroll)
        let hit = try #require(host.hitTest(center))
        #expect(hit === text || hit.isDescendant(of: scroll))
    }
}
