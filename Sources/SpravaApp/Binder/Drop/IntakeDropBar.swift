import AppKit
import SwiftUI

/// The binder page's drop bar, above its list and always in view: emails dragged from Outlook or Mail, attachments,
/// and files from Finder go to the binder's `intake/`, where each becomes a card to file. It sits above the List, so it
/// stays in reach however far the page is scrolled.
struct IntakeDropBar: View {
    let folder: URL
    @StateObject private var model: IntakeDropModel
    @State private var targeted = false

    init(folder: URL, model: @autoclosure @escaping () -> IntakeDropModel = IntakeDropModel()) {
        self.folder = folder
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                DropTarget(targeted: $targeted, refused: { model.explainWebDrag() }) { drop in
                    switch drop {
                    case .files(let urls, let promises): model.drop(urls, promises: promises, into: folder)
                    case .text(let html, let plain): model.dropText(html: html, plain: plain, into: folder)
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down").foregroundStyle(targeted ? Color.accentColor : .secondary)
                    Text(targeted ? "Release to add to this binder's intake" : "Drop emails or files here")
                        .foregroundStyle(targeted ? .primary : .secondary)
                    Text("from Outlook, Mail or Finder; the originals stay where they are").font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if model.busy { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12)
                .allowsHitTesting(false)
            }
            .frame(height: 38)
            .background(targeted ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Drop emails or files here to add them to this binder's intake")
            if let report = model.report {
                HStack(alignment: .firstTextBaseline) {
                    // No vertical fixedSize: outside the List, it would make the window's minimum height that of
                    // the report wrapped at no width, thousands of points, and push the page above the window's top.
                    Text(verbatim: report).font(.callout).foregroundStyle(model.problem ? .orange : .secondary)
                        .lineLimit(8).textSelection(.enabled).help(report)
                    Spacer(minLength: 0)
                    Button { model.dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
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

    static func offer(_ pasteboard: NSPasteboard) -> Offer {
        if pasteboard.canReadObject(forClasses: classes, options: options) { return .files }
        let types = pasteboard.types ?? []
        if types.contains(.html) || types.contains(.string) { return .text }
        return types.contains(webData) ? .webOnly : .nothing
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let offer = Self.offer(sender.draggingPasteboard)
        onTargeted(offer == .files || offer == .text)
        if offer == .webOnly { onRefused() }
        return offer == .files || offer == .text ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
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
