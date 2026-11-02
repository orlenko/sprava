import AppKit
import SwiftUI

/// A binder's whole page as a drop target: emails dragged from Outlook or Mail, attachments, and files from Finder go to the
/// binder's `intake/`, where each becomes a card to file. Text dragged onto a text being edited stays that text's own.
struct IntakeDropSurface<Content: View>: View {
    let folder: URL
    let enabled: Bool
    let content: Content
    @StateObject private var model: IntakeDropModel
    @State private var targeted = false

    init(folder: URL, enabled: Bool, model: @autoclosure @escaping () -> IntakeDropModel = IntakeDropModel(), @ViewBuilder content: () -> Content) {
        self.folder = folder
        self.enabled = enabled
        self.content = content()
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(spacing: 0) {
            if let report = model.report {
                HStack(alignment: .firstTextBaseline) {
                    // No vertical fixedSize: outside a List, it would make the window's minimum height that of the
                    // report wrapped at no width, thousands of points, and push the page above the window's top.
                    Text(verbatim: report).font(.callout).foregroundStyle(model.problem ? .orange : .secondary)
                        .lineLimit(8).textSelection(.enabled).help(report)
                    Spacer(minLength: 0)
                    Button { model.dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            }
            content
        }
        .overlay {
            if enabled {
                ZStack {
                    DropTarget(targeted: $targeted, refused: { model.explainWebDrag() }) { drop in
                        switch drop {
                        case .files(let urls, let promises): model.drop(urls, promises: promises, into: folder)
                        case .text(let html, let plain): model.dropText(html: html, plain: plain, into: folder)
                        }
                    }
                    if targeted {
                        RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06))
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                        Label("Release to add to this binder's intake", systemImage: "tray.and.arrow.down")
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.accentColor))
                            .allowsHitTesting(false)
                    }
                    if model.busy {
                        ProgressView().controlSize(.small).padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .allowsHitTesting(false)
                    }
                }
                .padding(2)
            }
        }
    }
}

/// The AppKit view that takes the drag: file URLs; the file promises Outlook, Mail and Photos send instead, which must
/// be asked for while the drop is performed; and selected text, which is how a message leaves a web app such as
/// Outlook on the web, whose dragged messages carry only the page's own data.
private struct DropTarget: NSViewRepresentable {
    @Binding var targeted: Bool
    let refused: () -> Void
    let dropped: (DropTargetView.Drop) -> Bool

    func makeNSView(context: Context) -> DropTargetView {
        let view = DropTargetView()
        view.registerForDraggedTypes(DropTargetView.types)
        return view
    }

    func updateNSView(_ view: DropTargetView, context: Context) {
        let binding = $targeted
        view.onTargeted = { value in if binding.wrappedValue != value { binding.wrappedValue = value } }
        view.onRefused = refused
        view.onDrop = dropped
    }
}

final class DropTargetView: NSView {
    enum Drop { case files([URL], [NSFilePromiseReceiver]), text(html: String?, plain: String?) }
    /// What a drag offers: files or promises; selected text; only a web page's private data (a message dragged out of
    /// a web app); or nothing Sprava can take.
    enum Offer: Equatable { case files, text, webOnly, nothing }
    static let webData = NSPasteboard.PasteboardType("org.chromium.web-custom-data")
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .html, .string, webData]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    private static let classes: [AnyClass] = [NSFilePromiseReceiver.self, NSURL.self]
    private static let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    var onTargeted: (Bool) -> Void = { _ in }
    var onRefused: () -> Void = {}
    var onDrop: (Drop) -> Bool = { _ in false }
    /// The text being edited that a text drag is over, which gets that drag instead of this view.
    private var editor: NSTextView?

    /// Clicks and scrolling go on to the page underneath; only drags stop here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func editor(in content: NSView, atWindowPoint point: NSPoint) -> NSTextView? {
        let inParent = content.superview?.convert(point, from: nil) ?? point
        guard let text = content.hitTest(inParent) as? NSTextView, text.isEditable else { return nil }
        return text
    }

    /// Follows a drag of text onto and off a text being edited. Files always come to the binder.
    private func routeToEditor(_ sender: NSDraggingInfo) -> NSTextView? {
        let current = Self.offer(sender.draggingPasteboard) == .text ? window?.contentView.flatMap { Self.editor(in: $0, atWindowPoint: sender.draggingLocation) } : nil
        if current !== editor {
            editor?.draggingExited(sender)
            editor = current
            _ = editor?.draggingEntered(sender)
        }
        return current
    }

    static func offer(_ pasteboard: NSPasteboard) -> Offer {
        if pasteboard.canReadObject(forClasses: classes, options: options) { return .files }
        let types = pasteboard.types ?? []
        if types.contains(.html) || types.contains(.string) { return .text }
        return types.contains(webData) ? .webOnly : .nothing
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let offer = Self.offer(sender.draggingPasteboard)
        if offer == .webOnly { onRefused() }
        return dragging(sender, offer: offer)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragging(sender, offer: Self.offer(sender.draggingPasteboard))
    }
    private func dragging(_ sender: NSDraggingInfo, offer: Offer) -> NSDragOperation {
        if let editor = routeToEditor(sender) {
            onTargeted(false)
            return editor.draggingUpdated(sender)
        }
        onTargeted(offer == .files || offer == .text)
        return offer == .files || offer == .text ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        editor?.draggingExited(sender)
        editor = nil
        onTargeted(false)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        editor = nil
        onTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        editor?.prepareForDragOperation(sender) ?? true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        editor?.concludeDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let editor { return editor.performDragOperation(sender) }
        let pasteboard = sender.draggingPasteboard
        switch Self.offer(pasteboard) {
        case .files:
            let objects = pasteboard.readObjects(forClasses: Self.classes, options: Self.options) ?? []
            return onDrop(.files(objects.compactMap { $0 as? URL }, objects.compactMap { $0 as? NSFilePromiseReceiver }))
        case .text:
            return onDrop(.text(html: pasteboard.string(forType: .html), plain: pasteboard.string(forType: .string)))
        case .webOnly, .nothing:
            return false
        }
    }
}
