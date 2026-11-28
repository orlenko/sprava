import AppKit
import Foundation
@testable import SpravaApp
import SpravaKit
import SwiftUI
import Testing

/// ⌘V on a binder's page (conversation.md 5.1, decisions.md D51): what the clipboard holds becomes files in the
/// binder's intake, and a paste of words into a text being edited stays that text's. Invented content only; every
/// test uses a clipboard of its own, never the person's.
@MainActor @Suite(.serialized) struct ClipboardPasteTests {
    typealias Runtime = IntakeDropModelTests.Runtime
    static let binder = IntakeDropModelTests.binder
    static let noon = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: 2026, month: 11, day: 28, hour: 10, minute: 32, second: 11))!
    /// Not an image: nothing here decodes one, so any bytes show that they arrive as they were.
    static let picture = Data("invented image bytes".utf8)

    func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("sprava-test-" + UUID().uuidString)); board.clearContents(); fill(board); return board
    }
    func settle(_ model: IntakeDropModel) async throws {
        for _ in 0..<400 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
    }
    func press(_ characters: String = "v", shown: String? = nil, flags: NSEvent.ModifierFlags = .command, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: shown ?? characters, isARepeat: false, keyCode: 9)!
    }

    @Test func oneCopyInSeveralFormsIsReadAsWhatItIs() {
        typealias P = ClipboardPaste
        let web = NSPasteboard.PasteboardType("public.url")
        // Files copied in Finder bring a name and an icon along.
        #expect(P.kind(of: [.fileURL, .string, .tiff], hasFiles: true) == .files)
        // A screenshot taken to the clipboard.
        #expect(P.kind(of: [.png, .tiff], hasFiles: false) == .image)
        // An image copied from a page, with its markup, or with its address as text.
        #expect(P.kind(of: [.png, .html], hasFiles: false) == .image)
        #expect(P.kind(of: [.tiff, web, .string], hasFiles: false) == .image)
        #expect(P.kind(of: [P.jpeg], hasFiles: false) == .image)
        // A selection from an office app comes as text in three forms with a picture and a PDF of it: it is text.
        #expect(P.kind(of: [.html, .rtf, .string, .pdf, .png], hasFiles: false) == .richText)
        #expect(P.kind(of: [.rtfd, .rtf, .string], hasFiles: false) == .richText)
        // A region copied from a PDF viewer.
        #expect(P.kind(of: [.pdf, .tiff], hasFiles: false) == .pdf)
        #expect(P.kind(of: [.string], hasFiles: false) == .text)
        #expect(P.kind(of: [.html], hasFiles: false) == .text)
        #expect(P.kind(of: [web], hasFiles: false) == .nothing)
        #expect(P.kind(of: [], hasFiles: false) == .nothing)
        // A secret a password manager copied is never taken, whatever form it has.
        #expect(P.kind(of: [.string, P.concealed], hasFiles: false) == .nothing)
        #expect(P.kind(of: [.fileURL, P.concealed], hasFiles: true) == .nothing)
        // Words are the text field's own while one is edited; files, a PDF and an image are the binder's.
        #expect(P.staysInEditor(.text) && P.staysInEditor(.richText))
        #expect(!P.staysInEditor(.files) && !P.staysInEditor(.image) && !P.staysInEditor(.pdf))
    }

    @Test func theClipboardsBytesAreTakenAsTheyAre() throws {
        typealias P = ClipboardPaste
        let files = board { $0.writeObjects([URL(fileURLWithPath: "/invented/one.pdf") as NSURL, URL(fileURLWithPath: "/invented/two.m4a") as NSURL]) }
        guard case .files(let urls)? = P.content(of: files) else { Issue.record("copied files were not read as files"); return }
        #expect(urls.map(\.path) == ["/invented/one.pdf", "/invented/two.m4a"])
        // The PNG is preferred to the TIFF beside it.
        let shot = board { $0.declareTypes([.tiff, .png], owner: nil); $0.setData(Data("tiff".utf8), forType: .tiff); $0.setData(Self.picture, forType: .png) }
        guard case .data(let data, let ext, let noun)? = P.content(of: shot) else { Issue.record("a screenshot was not read as an image"); return }
        #expect(data == Self.picture && ext == "png" && noun == "image")
        let tiff = board { $0.setData(Self.picture, forType: .tiff) }
        guard case .data(_, "tiff", "image")? = P.content(of: tiff) else { Issue.record("a TIFF was not kept as a TIFF"); return }
        let page = board { $0.declareTypes([.pdf, .tiff], owner: nil); $0.setData(Data("%PDF-invented".utf8), forType: .pdf); $0.setData(Self.picture, forType: .tiff) }
        guard case .data(_, "pdf", "document")? = P.content(of: page) else { Issue.record("a PDF was not read as a PDF"); return }
        let office = board {
            $0.declareTypes([.html, .rtf, .string, .png], owner: nil)
            $0.setString("<p>Invented paragraph</p>", forType: .html); $0.setData(Data("{\\rtf1 Invented}".utf8), forType: .rtf)
            $0.setString("Invented paragraph", forType: .string); $0.setData(Self.picture, forType: .png)
        }
        guard case .text(let html, let plain)? = P.content(of: office) else { Issue.record("an office selection was not read as text"); return }
        #expect(html == "<p>Invented paragraph</p>" && plain == "Invented paragraph")
        // Rich text with no markup stays the RTF it is.
        let notes = board { $0.declareTypes([.rtf, .string], owner: nil); $0.setData(Data("{\\rtf1 Invented}".utf8), forType: .rtf); $0.setString("Invented", forType: .string) }
        guard case .data(let rtf, "rtf", "text")? = P.content(of: notes) else { Issue.record("rich text was not kept as RTF"); return }
        #expect(rtf == Data("{\\rtf1 Invented}".utf8))
        guard case .text(nil, "Invented words")? = P.content(of: board { $0.setString("Invented words", forType: .string) }) else { Issue.record("plain text was not read"); return }
        #expect(P.content(of: board { $0.setString("", forType: .string) }) == nil)
        #expect(P.content(of: board { _ in }) == nil)
        #expect(P.content(of: board { $0.declareTypes([.string, P.concealed], owner: nil); $0.setString("invented-secret", forType: .string) }) == nil)
    }

    @Test func whatIsPastedBecomesAFileNamedForWhatItIsAndWhen() async throws {
        let runtime = Runtime(), model = IntakeDropModel(send: runtime.send)
        #expect(model.paste(.data(Self.picture, ext: "png", noun: "image"), into: Self.binder, now: Self.noon))
        try await settle(model)
        #expect(runtime.received.map(\.name) == ["Pasted image 2026-11-28 10.32.11.png"])
        #expect(runtime.received.first?.bytes == "invented image bytes")
        #expect(model.report == "Added to intake: Pasted image 2026-11-28 10.32.11.png. Each becomes a card to file within a minute.")
        #expect(model.paste(.text(html: "<p>Invented body</p>", plain: "Invented body"), into: Self.binder, now: Self.noon))
        try await settle(model)
        #expect(runtime.received.last?.name == "Pasted text 2026-11-28 10.32.11.html")
        #expect(runtime.received.last?.bytes == "<!doctype html><meta charset=\"utf-8\">\n<p>Invented body</p>")
        #expect(model.paste(.text(html: nil, plain: "Invented note"), into: Self.binder, now: Self.noon))
        try await settle(model)
        #expect(runtime.received.last?.name == "Pasted text 2026-11-28 10.32.11.txt")
        #expect(model.paste(.data(Data("%PDF-invented".utf8), ext: "pdf", noun: "document"), into: Self.binder, now: Self.noon))
        try await settle(model)
        #expect(runtime.received.last?.name == "Pasted document 2026-11-28 10.32.11.pdf")
        #expect(!model.paste(.data(Data(), ext: "png", noun: "image"), into: Self.binder))
        #expect(!model.paste(.text(html: "", plain: nil), into: Self.binder))
        #expect(runtime.received.count == 4)
    }

    @Test func copiedFilesGoTheWayDroppedFilesGo() async throws {
        let root = try IntakeDropModelTests.scratch(), runtime = Runtime(), model = IntakeDropModel(send: runtime.send)
        try Data("Invented recording".utf8).write(to: root.appendingPathComponent("interview.m4a"))
        try Data("Invented letter".utf8).write(to: root.appendingPathComponent("letter.pdf"))
        try Data("-----BEGIN INVENTED KEY-----".utf8).write(to: root.appendingPathComponent("server.pem"))
        let copied = board { $0.writeObjects(["interview.m4a", "letter.pdf", "server.pem"].map { root.appendingPathComponent($0) as NSURL }) }
        let content = try #require(ClipboardPaste.content(of: copied))
        #expect(model.paste(content, into: Self.binder))
        try await settle(model)
        #expect(runtime.received.map(\.name) == ["interview.m4a", "letter.pdf"])
        #expect(runtime.received.map(\.bytes) == ["Invented recording", "Invented letter"])
        #expect(model.report?.contains("server.pem, a key or credential file") == true)
    }

    // A selection copied with a picture or a file inside it: only its words can be taken, and the report says what was
    // left, as a problem, never a plain "Added".
    @Test func textCopiedWithAttachmentsIsTakenAsWordsAndThePageSaysWhatWasLeft() async throws {
        let rich = board {
            $0.declareTypes([.rtfd, .rtf, .string], owner: nil)
            $0.setData(Data("invented flat rtfd with a picture".utf8), forType: .rtfd); $0.setData(Data("{\\rtf1 Invented}".utf8), forType: .rtf); $0.setString("Invented", forType: .string)
        }
        #expect(ClipboardPaste.leavesAttachments(rich))
        #expect(ClipboardPaste.leavesAttachments(board { $0.declareTypes([.rtfd, .html, .string], owner: nil); $0.setString("<p>Invented</p>", forType: .html); $0.setString("Invented", forType: .string) }))
        #expect(!ClipboardPaste.leavesAttachments(board { $0.declareTypes([.rtf, .string], owner: nil); $0.setString("Invented", forType: .string) }))
        #expect(!ClipboardPaste.leavesAttachments(board { $0.setData(Self.picture, forType: .png) }))
        let runtime = Runtime(), model = IntakeDropModel(send: runtime.send)
        let content = try #require(ClipboardPaste.content(of: rich))
        #expect(model.paste(content, withoutAttachments: ClipboardPaste.leavesAttachments(rich), into: Self.binder, now: Self.noon))
        try await settle(model)
        #expect(runtime.received.map(\.name) == ["Pasted text 2026-11-28 10.32.11.rtf"])
        #expect(model.report == "Added to intake: Pasted text 2026-11-28 10.32.11.rtf. Each becomes a card to file within a minute.\n" + IntakeDropModel.attachmentsNote)
        #expect(model.problem)
        // The same words without attachments are reported plainly.
        #expect(model.paste(content, into: Self.binder, now: Self.noon))
        try await settle(model)
        #expect(model.report == "Added to intake: Pasted text 2026-11-28 10.32.11.rtf. Each becomes a card to file within a minute." && !model.problem)
    }

    @Test func aPasteOverItsBoundAddsNothingAndSaysSo() {
        let runtime = Runtime(), model = IntakeDropModel(send: runtime.send)
        #expect(!model.paste(.data(Data(count: IntakeDropModel.maxPastedBytes + 1), ext: "png", noun: "image"), into: Self.binder))
        #expect(model.report == "Nothing was added: the pasted image is over 200 MB." && model.problem && !model.busy)
        #expect(!model.paste(.text(html: nil, plain: String(repeating: "a", count: IntakeDropModel.maxTextBytes + 1)), into: Self.binder))
        #expect(model.report == "Nothing was added: the pasted text is over 16 MB.")
        #expect(runtime.received.isEmpty)
    }

    @Test func thePressIsTheBindersUnlessWordsAreBeingPastedIntoAText() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let editable = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let overlay = DropTargetView(frame: content.bounds)
        content.addSubview(editable); content.addSubview(overlay)
        window.contentView = content
        var held = board { _ in }
        var taken: [ClipboardPaste.Content] = [], lacking: [Bool] = []
        overlay.clipboard = { held }
        overlay.onDrop = { drop in
            if case .pasted(let content, let without) = drop { taken.append(content); lacking.append(without) }
            return true
        }
        let paste = press(in: window)

        // Nothing is being edited: files, an image and words all come to the binder.
        #expect(window.makeFirstResponder(nil))
        held = board { $0.writeObjects([URL(fileURLWithPath: "/invented/one.pdf") as NSURL]) }
        #expect(window.performKeyEquivalent(with: paste) && taken.count == 1)
        held = board { $0.setData(Self.picture, forType: .png) }
        #expect(window.performKeyEquivalent(with: paste) && taken.count == 2)
        held = board { $0.setString("Invented words", forType: .string) }
        #expect(window.performKeyEquivalent(with: paste) && taken.count == 3)
        // Text copied with a picture inside it is taken as its words, and the page is told that something was left.
        #expect(lacking == [false, false, false])
        held = board { $0.declareTypes([.rtfd, .rtf, .string], owner: nil); $0.setData(Data("invented flat rtfd".utf8), forType: .rtfd); $0.setData(Data("{\\rtf1 Invented}".utf8), forType: .rtf); $0.setString("Invented", forType: .string) }
        #expect(window.performKeyEquivalent(with: paste) && taken.count == 4 && lacking.last == true)
        guard case .data(_, "rtf", "text")? = taken.last else { Issue.record("the words of a selection with a picture were not taken as RTF"); return }
        taken.removeLast(); lacking.removeLast()
        // An empty clipboard, or a concealed secret, is no one's here.
        held = board { _ in }
        #expect(!window.performKeyEquivalent(with: paste))
        held = board { $0.declareTypes([.string, ClipboardPaste.concealed], owner: nil); $0.setString("invented-secret", forType: .string) }
        #expect(!window.performKeyEquivalent(with: paste) && taken.count == 3)

        // A text is being edited: words are its own and the press goes on; files and an image still come here.
        #expect(window.makeFirstResponder(editable))
        held = board { $0.setString("Invented words", forType: .string) }
        #expect(!window.performKeyEquivalent(with: paste) && taken.count == 3)
        held = board { $0.declareTypes([.html, .string], owner: nil); $0.setString("<b>Invented</b>", forType: .html); $0.setString("Invented", forType: .string) }
        #expect(!window.performKeyEquivalent(with: paste) && taken.count == 3)
        held = board { $0.setData(Self.picture, forType: .png) }
        #expect(window.performKeyEquivalent(with: paste) && taken.count == 4)
        held = board { $0.writeObjects([URL(fileURLWithPath: "/invented/two.m4a") as NSURL]) }
        #expect(window.performKeyEquivalent(with: paste) && taken.count == 5)
        guard case .files(let urls)? = taken.last else { Issue.record("the copied file did not arrive as a file"); return }
        #expect(urls.map(\.path) == ["/invented/two.m4a"])

        // Only ⌘V: another letter, or more modifiers, is not a paste. A layout of another script still is one.
        #expect(!window.performKeyEquivalent(with: press("c", in: window)))
        #expect(!window.performKeyEquivalent(with: press(flags: [.command, .shift], in: window)))
        #expect(!window.performKeyEquivalent(with: press(flags: [.command, .option], in: window)))
        #expect(window.performKeyEquivalent(with: press("v", shown: "м", in: window)) && taken.count == 6)
        // A page that is not shown takes nothing.
        overlay.isHidden = true
        #expect(!window.performKeyEquivalent(with: paste) && taken.count == 6)
    }

    // The press reaches the page as SwiftUI builds it: the real surface around a text field, hosted in a window, takes
    // a screenshot from the clipboard through the model to the runtime while the field is being edited.
    @Test func thePageAsBuiltTakesAScreenshotWhileItsFieldIsEdited() async throws {
        let runtime = Runtime(), model = IntakeDropModel(send: runtime.send)
        let page = IntakeDropSurface(folder: Self.binder, enabled: true, model: model) {
            VStack { TextField("Message", text: .constant("")); List { Text("Invented row") } }
        }.frame(width: 600, height: 400)
        let host = NSHostingView(rootView: page)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
        func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
            (view as? V) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        let overlay = try #require(find(DropTargetView.self, in: host))
        let shot = board { $0.setData(Self.picture, forType: .png) }
        overlay.clipboard = { shot }
        let field = try #require(find(NSTextField.self, in: host))
        #expect(window.makeFirstResponder(field))
        #expect((window.firstResponder as? NSTextView)?.isEditable == true)
        #expect(window.performKeyEquivalent(with: press(in: window)))
        try await settle(model)
        #expect(runtime.received.count == 1 && runtime.received.first?.bytes == "invented image bytes")
        #expect(runtime.received.first?.name.hasPrefix("Pasted image ") == true && runtime.received.first?.name.hasSuffix(".png") == true)
        // Words on the clipboard are the field's: the page lets the press go on.
        let words = board { $0.setString("Invented words", forType: .string) }
        overlay.clipboard = { words }
        #expect(!overlay.performKeyEquivalent(with: press(in: window)))
        #expect(runtime.received.count == 1)
    }
}
