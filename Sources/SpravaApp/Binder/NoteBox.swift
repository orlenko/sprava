import BinderStore
import Combine
import Foundation
import Services
import Shelf
import SpravaKit
import SwiftUI

/// The note box at the top of a binder's page: what the person types there is saved as a capture event with this
/// binder as its hint (capture-event-v0 §8.1), so its card is made here, not in the Inbox. The page keeps one
/// model while the person moves between binders, so each binder keeps its own draft, and a note is always sent
/// with the binder it was typed in.
@MainActor
final class BinderNote: ObservableObject {
    /// Why a note typed here would not be filed here by the runtime, read off the main actor.
    enum Route: Equatable, Sendable {
        case here
        /// Disclosure `none`: a hint never files into it without the person picking it on the card (architecture 8).
        case privateBinder
        /// Another Mac keeps this binder; only that Mac files into it.
        case otherMac
    }

    /// The draft of the binder shown.
    @Published var text = ""
    @Published private(set) var message: String?
    /// The binders whose note is being saved: the box is locked meanwhile, and cleared once the note is in.
    @Published private(set) var saving: Set<URL> = []
    private(set) var folder: URL?
    private(set) var startedTyping: Date?
    private var drafts: [URL: (text: String, started: Date?)] = [:]
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

    /// Saves the draft of `row`'s binder, the one shown, and returns whether it was saved. `sharesName` is true
    /// when another adopted binder has the same name: a hint is a name, so it could land there, and the note is
    /// sent without one. The draft is cleared only if it is still the text saved.
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
        let elsewhere: String? = if sharesName {
            "Another binder is also called \(row.name), so this note waits in the Inbox. File it into this binder from there."
        } else {
            switch route {
            case .privateBinder?: "This binder is private, so Sprava files nothing into it on its own. The note waits in the Inbox; file it into this binder from there."
            case .otherMac?: "Another Mac keeps this binder, so the note waits in the Inbox."
            case nil: "Sprava could not check this binder, so the note waits privately in the Inbox. File it into this binder from there."
            case .here?: nil
            }
        }
        let outcome = await NoteWriter.save(words, binderHint: elsewhere == nil ? row.name : nil, startedAt: started,
                                            client: client, support: support, isPrivate: isPrivate)
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
            message = !noticed ? "Saved, but Sprava's background part did not answer, so the note waits in the Inbox for you to pick its binder."
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

/// The box itself, drawn at the top of the page.
struct NoteBox: View {
    @ObservedObject var note: BinderNote
    let row: ShelfRow
    let sharesName: Bool
    /// Called once a note is saved, so the page reads its new card.
    let added: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $note.text)
                    .font(.body)
                    .frame(minHeight: 60)
                    .disabled(note.isSaving)
                    .onChange(of: note.text) { _, new in note.changed(new) }
                    .overlay(alignment: .topLeading) {
                        if note.text.isEmpty {
                            Text("Tell this binder\u{2026}").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                HStack {
                    Text("One line per thing to do. It comes to this binder as a card for your OK.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add") {
                        Task { if await note.add(row, sharesName: sharesName) { added() } }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(note.isSaving || note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let message = note.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
        }
    }
}
