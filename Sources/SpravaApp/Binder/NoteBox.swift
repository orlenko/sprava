import BinderStore
import Combine
import Foundation
import Services
import Shelf
import SpravaKit
import SwiftUI

/// The note box at the top of a binder's page: what the person types there is saved as a capture event with this
/// binder as its explicit destination in the runtime's notice, so its card is made here, not in the Inbox. The page keeps one
/// model while the person moves between binders, so each binder keeps its own draft, and a note is always sent
/// with the binder it was typed in.
@MainActor
final class BinderNote: ObservableObject, DraftOwner {
    /// The binder's privacy or foreign ownership, read off the main actor.
    enum Route: Equatable, Sendable {
        case here
        /// Disclosure `none`: a name hint alone cannot select it (architecture 8).
        case privateBinder
        /// Another Mac keeps this binder; only that Mac files into it.
        case otherMac
    }

    /// The draft of the binder shown.
    @Published var text = ""
    /// Opened by the person while the binder's conversation is the page's input: the box that adds to-dos without
    /// Claude stays one click away.
    @Published var directOpen = false
    /// Whether the box shows while the conversation is the page's input: when opened, and always while it holds a
    /// draft or a message, so nothing typed or reported is ever out of sight.
    var directShown: Bool { directOpen || !text.isEmpty || message != nil }
    @Published private(set) var message: String?
    /// The binders whose note is being saved: the box is locked meanwhile, and cleared once the note is in.
    @Published private(set) var saving: Set<URL> = []
    private(set) var folder: URL?
    private(set) var startedTyping: Date?
    private var drafts: [URL: (text: String, started: Date?)] = [:]
    var draftState: DraftState {
        DraftState(hasChanges: !text.isEmpty || drafts.values.contains { !$0.text.isEmpty }, saving: !saving.isEmpty)
    }
    let client: RuntimeClient
    let support: URL
    private let disk: ShelfDiskWorker
    private let readRoute: @Sendable (ShelfRow, URL) -> Route

    init(client: RuntimeClient = RuntimeClient(), support: URL = SpravaPaths.supportDirectory(),
         readRoute: @escaping @Sendable (ShelfRow, URL) -> Route = BinderNote.route,
         deadline: @escaping DiskDeadline = ShelfDiskWorker.wallClock) {
        self.client = client
        self.support = support
        self.readRoute = readRoute
        self.disk = ShelfDiskWorker(queue: DispatchQueue(label: "sprava.binder.note", qos: .userInitiated), deadline: deadline)
    }

    var isSaving: Bool { folder.map { saving.contains($0) } ?? false }

    /// Shows `folder`'s draft, setting aside the one typed in the binder left.
    func show(_ folder: URL) {
        let folder = folder.standardizedFileURL
        guard self.folder != folder else { return }
        if let left = self.folder {
            drafts[left] = text.isEmpty ? nil : (text, startedTyping)
        }
        self.folder = folder
        let kept = drafts.removeValue(forKey: folder)
        text = kept?.text ?? ""
        startedTyping = kept?.started
        message = nil
    }

    /// The note's capture time is when its words were started, as in the Inbox.
    func changed(_ text: String, now: Date = Date()) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            startedTyping = nil
        } else if startedTyping == nil {
            startedTyping = now
        }
    }

    /// Saves into the physical binder selected on screen. An ambiguous name is omitted as a hint,
    /// while the authenticated notice still keeps the selected folder. Clear only the text saved.
    func add(_ row: ShelfRow, sharesName: Bool) async -> Bool {
        let folder = row.folder.standardizedFileURL
        guard self.folder == folder, !saving.contains(folder) else { return false }
        let submitted = text
        let words = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        saving.insert(folder)
        defer { saving.remove(folder) }
        let started = startedTyping ?? Date()
        let read = readRoute
        let support = support
        // A duplicate name changes the destination hint, never the note's privacy. If the read times out,
        // keep the note private in the Inbox until the person can choose its destination.
        let route = await disk.run(timeout: 5) { read(row, support) }
        let isPrivate = route == .privateBinder || route == nil
        let elsewhere: String? = switch route {
            case .privateBinder?, .here?: nil
            case .otherMac?: "Another Mac keeps this binder, so the note waits in the Inbox."
            case nil: "Sprava could not check this binder, so the note waits privately in the Inbox. File it into this binder from there."
        }
        let destination = route == .here || route == .privateBinder ? folder : nil
        let outcome = await NoteWriter.save(words, binderHint: route == .here && !sharesName ? row.name : nil, startedAt: started,
                                            client: client, support: support, isPrivate: isPrivate, binder: destination)
        let shown = self.folder == folder
        guard case .saved(let noticed) = outcome else {
            if shown, case .refused(let why) = outcome { message = why }
            return false
        }
        if shown, text == submitted {
            text = ""
            startedTyping = nil
        } else if drafts[folder]?.text == submitted {
            drafts[folder] = nil
        }
        if shown {
            message = !noticed ? "Saved. The background part did not confirm its destination; check this binder and the Inbox before saving another copy."
                : elsewhere ?? "Added. Its card shows below, under Waiting for your OK, in a moment."
        }
        return true
    }

    /// Whether the runtime would file a note hinted at `row` into it, as its code-built card decides (architecture 8).
    nonisolated static func route(_ row: ShelfRow, support: URL) -> Route {
        if PrivacyRatchet.disclosure(row) == "none" { return .privateBinder }
        if let id = try? DeviceID.existing(support: support), Owner.device(of: row.folder) != id { return .otherMac }
        return .here
    }
}

/// The box itself, drawn at the top of the page. It adds to-dos; it does not answer, so it says so (2026-10-28: a
/// question typed into "Tell this binder" became a to-do).
struct NoteBox: View {
    static let placeholder = "Add to-dos, one per line\u{2026}"
    @ObservedObject var note: BinderNote
    let row: ShelfRow
    let sharesName: Bool
    /// Called once a note is saved, so the page reads its new card.
    let added: () -> Void
    /// True while the binder's conversation is the page's input: this box is then the way to add to-dos without
    /// Claude, and leaves Command-Return to the conversation's Send.
    var talking = false

    /// This box as shown below a connected conversation.
    func besideConversation() -> NoteBox { var box = self; box.talking = true; return box }

    var caption: String {
        talking ? "Each line becomes a to-do card here for your OK, without Claude."
            : "Each line becomes a to-do card here for your OK. To ask this binder questions, connect it to Claude below."
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                DraftEditor(text: $note.text, placeholder: Self.placeholder)
                    .disabled(note.isSaving)
                    .onChange(of: note.text) { _, new in note.changed(new) }
                HStack {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add") {
                        Task { if await note.add(row, sharesName: sharesName) { added() } }
                    }
                    .keyboardShortcut(talking ? nil : KeyboardShortcut(.return, modifiers: .command))
                    .disabled(note.isSaving || note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let message = note.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
        }
    }
}
