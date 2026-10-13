import AppKit

/// Registration credentials stay on this Mac, out of well-behaved clipboard history, and expire (architecture 7.5).
@MainActor
enum ProtectedClipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general,
                     lifetime: Duration = .seconds(60)) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: concealed), item.setData(Data(), forType: transient) else { return false }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects([item]) else { return false }
        let written = pasteboard.changeCount
        Task { @MainActor in
            do { try await Task.sleep(for: lifetime) } catch { return }
            // Clearing a later clipboard value would lose something else the person copied.
            if pasteboard.changeCount == written { pasteboard.clearContents() }
        }
        return true
    }
}
