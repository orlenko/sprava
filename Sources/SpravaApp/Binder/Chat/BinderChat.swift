import BinderFormat
import Combine
import Foundation
import Services

/// One binder's conversation on its page (conversation.md §3): the person's lines, the binder's replies as they
/// stream, the changes each turn made with their Undo, and Stop. It talks only to `ChatCommands`, so the page works
/// against a stand-in until the binder's own back office answers (§15 PR 6). The model keeps one thread per binder
/// while the person moves between binders: a reply keeps streaming into its own binder's thread, and leaving a page
/// never stops a turn (only Stop does). Nothing here logs or notifies; the text is for this page only.
@MainActor
final class BinderChat: ObservableObject {
    struct Entry: Identifiable, Equatable {
        enum Speaker: Equatable { case person, binder }
        enum State: Equatable {
            /// From the binder's saved history: shown, never acted on (binder-v0 §7.2.1).
            case earlier
            case sending
            case sent
            /// Not accepted; Retry sends it again under the same request id, so it is never a second turn.
            case notSent(String)
            case replying
            case replied
            case stopped
            /// The stream ended without the turn saying it finished: never shown as a complete reply.
            case incomplete
            case failed(String)
        }
        let id: UUID
        let speaker: Speaker
        var text: String
        var state: State
        /// What the binder is doing now, shown while it replies.
        var activity: String?
        var changes: [ChatBinderChange] = []
        /// A person's line: the request id a retry repeats.
        var requestID: UUID?
    }

    /// One binder's conversation as the page keeps it.
    struct Thread {
        var draft = ""
        var entries: [Entry] = []
        var turn: UUID?
        var stopping = false
        var message: String?
        var historyNote: String?
        var undone: Set<String> = []
    }

    /// A reply longer than this is cut on screen, so a runaway stream cannot exhaust the app's memory.
    nonisolated static let maximumReplyBytes = ChatCommands.maximumLineBytes
    /// The months of saved history shown when a binder opens, newest last.
    nonisolated static let historyMonths = 2

    @Published private var threads: [URL: Thread] = [:]
    /// The binder shown; published, so moving to a binder already read redraws the page.
    @Published private(set) var folder: URL?
    private let commands: ChatCommands?
    private let binderID: (URL) -> String?
    private let undoChange: ((ChatUndoReference, URL) async throws -> Void)?
    private let readHistory: @Sendable (URL) async -> (entries: [Entry], note: String?)
    /// Called after a turn changed the binder, so the page reads it again.
    var changed: (URL) -> Void = { _ in }

    /// `binderID` gives the binder owner's opaque identity, never a path or a name; without one the binder cannot
    /// hold a conversation yet.
    init(commands: ChatCommands?, binderID: @escaping (URL) -> String?,
         undo: ((ChatUndoReference, URL) async throws -> Void)? = nil,
         readHistory: @escaping @Sendable (URL) async -> (entries: [Entry], note: String?) = BinderChat.history) {
        self.commands = commands
        self.binderID = binderID
        self.undoChange = undo
        self.readHistory = readHistory
    }

    // MARK: - What the page shows

    private var shown: Thread { folder.flatMap { threads[$0] } ?? Thread() }
    var entries: [Entry] { shown.entries }
    var message: String? { shown.message }
    var historyNote: String? { shown.historyNote }
    var isReplying: Bool { shown.turn != nil }
    var isStopping: Bool { shown.stopping }
    var isAvailable: Bool { commands != nil && folder.flatMap(binderID) != nil }
    var draft: String {
        get { shown.draft }
        set { if let folder { threads[folder, default: Thread()].draft = newValue } }
    }
    var canSend: Bool {
        isAvailable && !isReplying && !shown.entries.contains { $0.state == .sending }
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func isUndone(_ change: ChatBinderChange) -> Bool { change.undo.map { shown.undone.contains($0.batchID) } ?? false }

    /// Shows `folder`'s conversation, reading its saved history the first time.
    func show(_ folder: URL) async {
        let folder = folder.standardizedFileURL
        self.folder = folder
        guard threads[folder] == nil else { return }
        threads[folder] = Thread()
        let (earlier, note) = await readHistory(folder)
        threads[folder]?.entries.insert(contentsOf: earlier, at: 0)
        threads[folder]?.historyNote = note
    }

    // MARK: - Sending

    /// Sends the draft of the binder shown. The draft leaves the composer at once and comes back if the line is not
    /// accepted while the composer is still empty, so nothing the person typed is lost.
    func send() async {
        guard let folder, canSend, let commands, let binder = binderID(folder) else { return }
        let line = draft
        let entry = Entry(id: UUID(), speaker: .person, text: line, state: .sending, requestID: UUID())
        threads[folder]?.draft = ""
        threads[folder]?.message = nil
        threads[folder]?.entries.append(entry)
        await deliver(entry, binder: binder, in: folder, through: commands)
    }

    /// Sends a line that was not accepted again, with its first request id.
    func retry(_ entry: Entry) async {
        guard let folder, let commands, let binder = binderID(folder), shown.turn == nil,
              case .notSent = entry.state, entry.speaker == .person else { return }
        update(entry.id, in: folder) { $0.state = .sending }
        await deliver(entry, binder: binder, in: folder, through: commands)
    }

    private func deliver(_ entry: Entry, binder: String, in folder: URL, through commands: ChatCommands) async {
        guard let requestID = entry.requestID else { return }
        do {
            let turn = try await commands.send(ChatSendRequest(binderID: binder, requestID: requestID, text: entry.text))
            update(entry.id, in: folder) { $0.state = .sent }
            let reply = Entry(id: UUID(), speaker: .binder, text: "", state: .replying)
            threads[folder]?.entries.append(reply)
            threads[folder]?.turn = turn.turnID
            Task { await self.follow(turn, reply: reply.id, in: folder) }
        } catch {
            update(entry.id, in: folder) { $0.state = .notSent(Self.words(error)) }
            if threads[folder]?.draft.isEmpty == true { threads[folder]?.draft = entry.text }
        }
    }

    /// Reads a turn's events into its reply until the turn says it finished or failed.
    private func follow(_ turn: ChatTurn, reply: UUID, in folder: URL) async {
        var ended = false
        for await event in turn.events {
            switch event {
            case .textDelta(let piece):
                update(reply, in: folder) { entry in
                    guard entry.text.utf8.count < Self.maximumReplyBytes else { return }
                    entry.text += piece
                    if entry.text.utf8.count >= Self.maximumReplyBytes { entry.text += "\n[The rest of this reply is not shown.]" }
                }
            case .activity(let doing):
                update(reply, in: folder) { $0.activity = doing }
            case .binderChanged(let change):
                update(reply, in: folder) { $0.changes.append(change) }
                changed(folder)
            case .finished(let how):
                update(reply, in: folder) { $0.state = how == .replied ? .replied : .stopped }
                ended = true
            case .failed(let failure):
                update(reply, in: folder) { $0.state = .failed(Self.words(failure)) }
                ended = true
            }
            if ended { break }
        }
        if !ended { update(reply, in: folder) { $0.state = .incomplete } }
        update(reply, in: folder) { $0.activity = nil }
        if threads[folder]?.turn == turn.turnID {
            threads[folder]?.turn = nil
            threads[folder]?.stopping = false
        }
    }

    /// Asks the binder to stop the turn running on the page shown. Changes already made keep their Undo.
    func stop() async {
        guard let folder, let commands, let binder = binderID(folder), let turn = shown.turn, !shown.stopping else { return }
        threads[folder]?.stopping = true
        do {
            try await commands.interrupt(binderID: binder, turnID: turn)
        } catch {
            threads[folder]?.stopping = false
            threads[folder]?.message = "Could not stop the reply: \(Self.words(error))"
        }
    }

    /// Undoes the changes one reply made, through the binder's owner.
    func undo(_ change: ChatBinderChange) async {
        guard let folder, let reference = change.undo, let undoChange, !isUndone(change) else { return }
        do {
            try await undoChange(reference, folder)
            threads[folder]?.undone.insert(reference.batchID)
            changed(folder)
        } catch {
            threads[folder]?.message = "\(error)"
        }
    }

    private func update(_ id: UUID, in folder: URL, _ change: (inout Entry) -> Void) {
        guard let index = threads[folder]?.entries.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[folder]!.entries[index])
    }

    static func words(_ error: Error) -> String {
        switch error as? ChatCommandFailure {
        case .invalidRequest?: "This line cannot be sent as it is."
        case .busy?: "The binder is still busy with another reply. Try again in a moment."
        case .unavailable?: "The binder could not be reached."
        case .cancelled?: "Sending was cancelled."
        case nil: "The binder could not be reached."
        }
    }

    // MARK: - Saved history

    /// The last months of the binder's saved conversation, display-only (binder-v0 §7.2.1), read off the main actor.
    nonisolated static func history(_ folder: URL) async -> (entries: [Entry], note: String?) {
        await Task.detached(priority: .userInitiated) { () -> (entries: [Entry], note: String?) in
            guard case .months(let months) = ConversationHistory.months(in: folder) else {
                return ([], "Earlier messages could not be read; they were left as they are.")
            }
            var entries: [Entry] = [], damaged = false
            for month in months.suffix(historyMonths) {
                guard case .month(let read) = ConversationHistory.read(month: month, in: folder) else { damaged = true; continue }
                damaged = damaged || !read.damage.isEmpty
                entries += read.messages.map { message in
                    Entry(id: UUID(), speaker: message.speaker == .person ? .person : .binder, text: message.text, state: .earlier)
                }
            }
            return (entries, damaged ? "Some earlier messages could not be read; they were left as they are." : nil)
        }.value
    }
}
