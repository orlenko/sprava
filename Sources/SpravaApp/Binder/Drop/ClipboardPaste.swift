import AppKit
import Foundation

/// What ⌘V on a binder's page takes from the clipboard (conversation.md 5.1, decisions.md D51): whatever a drop takes,
/// and what only a clipboard holds, such as a screenshot. Each becomes a file in the binder's `intake/`, where the
/// reader works out what it is. The app decodes nothing here: an image, a PDF or rich text is kept as the bytes the
/// other app put there, and the sandboxed reader is the first to open them.
@MainActor
enum ClipboardPaste {
    /// What the clipboard holds, as the page reads it. One copy often carries several forms of the same thing, so
    /// the order matters:
    /// - files copied in Finder come first, whatever else describes them (a name, an icon);
    /// - text with its formatting beside it is a selection of text, even when the app adds a picture of it, as
    ///   office apps do;
    /// - then a PDF, then an image (a screenshot, an image copied from a page, which may bring its address or its
    ///   markup along);
    /// - then text in one form only.
    enum Kind: Equatable { case files, richText, pdf, image, text, nothing }

    /// What is handed on to become files.
    enum Content {
        case files([URL])
        case text(html: String?, plain: String?)
        /// Bytes kept as they are, with the extension of their form and the word the file is named with.
        case data(Data, ext: String, noun: String)
    }

    static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    static let heic = NSPasteboard.PasteboardType("public.heic")
    static let gif = NSPasteboard.PasteboardType("com.compuserve.gif")
    /// What password managers mark a copied secret with. A clipboard that carries it is left alone: a password
    /// pasted beside a field would otherwise become a file in the binder.
    static let concealed = ProtectedClipboard.concealed
    /// The image forms taken, the one tried first being the one the intake reader opens most cheaply.
    static let images: [(type: NSPasteboard.PasteboardType, ext: String)] =
        [(.png, "png"), (jpeg, "jpg"), (heic, "heic"), (.tiff, "tiff"), (gif, "gif")]
    private static let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    static func kind(of types: [NSPasteboard.PasteboardType], hasFiles: Bool) -> Kind {
        if types.contains(concealed) { return .nothing }
        if hasFiles { return .files }
        let formatted = types.contains(.html) || types.contains(.rtf) || types.contains(.rtfd)
        if formatted, types.contains(.string) { return .richText }
        if types.contains(.pdf) { return .pdf }
        if images.contains(where: { types.contains($0.type) }) { return .image }
        return formatted || types.contains(.string) ? .text : .nothing
    }

    static func kind(of pasteboard: NSPasteboard) -> Kind {
        kind(of: pasteboard.types ?? [], hasFiles: pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOptions))
    }

    /// Whether a paste of this kind is the text field's own while one is being edited: text is, so typing and
    /// pasting words work as everywhere. Files, a PDF and an image are the binder's even then, since a field of
    /// words has no use for them.
    static func staysInEditor(_ kind: Kind) -> Bool { kind == .richText || kind == .text }

    /// The clipboard's content in its preferred form; nil when it holds nothing the page takes, or nothing at all
    /// in the form its types announced.
    static func content(of pasteboard: NSPasteboard) -> Content? {
        switch kind(of: pasteboard) {
        case .files:
            let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) ?? []).compactMap { $0 as? URL }
            return urls.isEmpty ? nil : .files(urls)
        case .richText, .text:
            // The markup when there is some, as for dragged text; rich text with no markup is kept as the RTF it is.
            let html = pasteboard.string(forType: .html), plain = pasteboard.string(forType: .string)
            if html?.isEmpty == false { return .text(html: html, plain: plain) }
            if let rtf = pasteboard.data(forType: .rtf), !rtf.isEmpty { return .data(rtf, ext: "rtf", noun: "text") }
            return plain?.isEmpty == false ? .text(html: nil, plain: plain) : nil
        case .pdf:
            return pasteboard.data(forType: .pdf).flatMap { $0.isEmpty ? nil : .data($0, ext: "pdf", noun: "document") }
        case .image:
            for image in images {
                if let data = pasteboard.data(forType: image.type), !data.isEmpty { return .data(data, ext: image.ext, noun: "image") }
            }
            return nil
        case .nothing:
            return nil
        }
    }

    /// ⌘V and nothing more. With Command held, a layout of another script reports the Latin letter in `characters`,
    /// which is how the menu's own shortcut finds it.
    static func isPaste(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command else { return false }
        return event.characters?.lowercased() == "v" || event.charactersIgnoringModifiers?.lowercased() == "v"
    }
}
