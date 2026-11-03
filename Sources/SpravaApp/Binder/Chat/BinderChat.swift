import BinderFormat
import Combine
import Foundation
import Services
import SpravaKit

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
        var isNotSent: Bool { if case .notSent = state { true } else { false } }
        var text: String
        var state: State
        /// What the binder is doing now, shown while it replies.
        var activity: String?
        var changes: [ChatBinderChange] = []
        /// A person's line: the request id a retry repeats. A reply: the request id of the line it answers.
        var requestID: UUID?
        /// Why this reply did not finish, and what the person can do about it.
        var problem: ReplyProblem?
        /// The reply reached its size limit; nothing more is added to it.
        var cutShort = false
        /// More changes came than the page keeps; the rest are in the binder's history.
        var changesCut = false
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
        var history = HistoryState.unread
        var historyRevision = UUID()
        /// The request whose line the page put back in the composer, until the person types.
        var restored: UUID?
    }

    enum HistoryState { case unread, reading, read }

    /// A reply longer than this is cut on screen, so a runaway stream cannot exhaust the app's memory.
    nonisolated static let maximumReplyBytes = ChatCommands.maximumLineBytes
    /// The months of saved history shown when a binder opens, newest last.
    nonisolated static let historyMonths = 2
    /// The changes one reply keeps on the page, and the bytes of each summary and reference, so a runaway stream
    /// cannot fill the app's memory with them.
    static let maximumChanges = 200
    static let maximumChangeBytes = 1024

    /// Threads by the binder's opaque identity, so a renamed or moved binder keeps its thread and a binder that
    /// replaced another at the same place does not inherit it.
    @Published private var threads: [String: Thread] = [:]
    /// The binder shown; published, so moving to a binder already read redraws the page.
    @Published private(set) var folder: URL?
    private let commands: ChatCommands?
    private let binderID: (URL) -> String?
    private let binderReady: (URL) -> Bool
    private let undoChange: ((ChatUndoReference, URL) async throws -> Void)?
    private let readHistory: @Sendable (URL) async -> (entries: [Entry], note: String?)
    /// Called after a turn changed the binder, so the page reads it again.
    var changed: (URL) -> Void = { _ in }
    /// Asks the binder again about an accepted turn, from its durable record.
    var reattach: ((_ binderID: String, _ requestID: UUID, _ turnID: UUID, _ folder: URL) -> ChatTurn)?

    /// `binderID` gives the binder owner's opaque identity, never a path or a name; without one the binder cannot
    /// hold a conversation yet.
    init(commands: ChatCommands?, binderID: @escaping (URL) -> String?, ready: @escaping (URL) -> Bool = { _ in true },
         undo: ((ChatUndoReference, URL) async throws -> Void)? = nil,
         readHistory: @escaping @Sendable (URL) async -> (entries: [Entry], note: String?) = BinderChat.history) {
        self.commands = commands
        self.binderID = binderID
        self.binderReady = ready
        self.undoChange = undo
        self.readHistory = readHistory
    }

    // MARK: - What the page shows

    private func key(_ folder: URL) -> String { binderID(folder).map { "binder:" + $0 } ?? "folder:" + folder.path }
    private var shownKey: String? { folder.map(key) }
    private var shown: Thread { shownKey.flatMap { threads[$0] } ?? Thread() }
    var entries: [Entry] { shown.entries }
    var message: String? { shown.message }
    var historyNote: String? { shown.historyNote }
    var draftState: DraftState {
        DraftState(hasChanges: threads.values.contains { thread in
            !thread.draft.isEmpty || thread.entries.contains { $0.speaker == .person && $0.isNotSent }
        }, saving: threads.values.contains { $0.entries.contains { $0.state == .sending } })
    }
    var isReplying: Bool { shown.turn != nil }
    var isStopping: Bool { shown.stopping }
    var isAvailable: Bool { commands != nil && folder.flatMap(binderID) != nil && folder.map(binderReady) == true }
    var draft: String {
        get { shown.draft }
        set {
            guard let shownKey else { return }
            threads[shownKey, default: Thread()].draft = newValue
            threads[shownKey]?.restored = nil   // typed by the person: no longer the line put back
        }
    }
    var canSend: Bool {
        isAvailable && !isReplying && !shown.entries.contains { $0.state == .sending }
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func isUndone(_ change: ChatBinderChange) -> Bool { change.undo.map { shown.undone.contains($0.batchID) } ?? false }

    /// Shows `folder`'s conversation, reading its saved history the first time.
    func show(_ folder: URL) async {
        let folder = folder.standardizedFileURL
        // The binder left keeps its draft and any running reply; its saved history is read again on return, so
        // visiting many binders never holds all their histories at once.
        if let left = shownKey, left != key(folder) {
            threads[left]?.entries.removeAll { $0.state == .earlier }
            threads[left]?.historyNote = nil
            threads[left]?.history = .unread
        }
        self.folder = folder
        let key = key(folder)
        if threads[key] == nil { threads[key] = Thread() }
        guard threads[key]?.history == .unread else { return }
        threads[key]?.history = .reading
        let revision = threads[key]?.historyRevision
        let (earlier, note) = await readHistory(folder)
        // A page left while its history was read installs nothing; the next visit reads it again.
        guard !Task.isCancelled, shownKey == key, threads[key]?.historyRevision == revision else { threads[key]?.history = .unread; return }
        let kept = threads[key]?.entries ?? []
        let ids = Set(kept.map(\.id))
        threads[key]?.entries = earlier.filter { !ids.contains($0.id) } + kept
        threads[key]?.historyNote = note
        threads[key]?.history = .read
    }

    /// Called after the runtime's clear barrier; the composer stays until the person sends it.
    func forgetHistory(_ folder: URL) {
        let key = key(folder.standardizedFileURL)
        threads[key]?.entries.removeAll()
        threads[key]?.restored = nil
        threads[key]?.historyRevision = UUID()
        threads[key]?.history = .unread
        threads[key]?.turn = nil
    }

    /// Reattach to an accepted turn from durable history; never send the person's line again.
    func needsResume(requestID: UUID, in folder: URL) -> Bool {
        guard let thread = threads[key(folder.standardizedFileURL)], thread.turn == nil else { return false }
        return thread.entries.contains { $0.speaker == .person && $0.requestID == requestID }
    }

    func resume(_ turn: ChatTurn, in folder: URL) {
        let folder = folder.standardizedFileURL
        guard binderID(folder) == turn.binderID, needsResume(requestID: turn.requestID, in: folder) else { return }
        let key = key(folder)
        let reply = Entry(id: turn.turnID, speaker: .binder, text: "", state: .replying, requestID: turn.requestID)
        if let index = threads[key]?.entries.firstIndex(where: { $0.id == reply.id }) {
            threads[key]?.entries[index] = reply
        } else { threads[key]?.entries.append(reply) }
        threads[key]?.turn = turn.turnID
        threads[key]?.stopping = false
        Task { await self.follow(turn, reply: reply.id, key: key, folder: folder) }
    }

    // MARK: - Sending

    /// Sends the draft of the binder shown. The draft leaves the composer at once and comes back if the line is not
    /// accepted while the composer is still empty, so nothing the person typed is lost.
    func send() async {
        guard let folder, canSend, let commands, let binder = binderID(folder) else { return }
        let key = key(folder)
        // Sending again a line that was not accepted is its Retry: the same request id, never a second turn.
        if let failed = shown.entries.last(where: { $0.speaker == .person && $0.isNotSent }),
           failed.requestID != nil, shown.restored == failed.requestID {
            threads[key]?.draft = ""
            await retry(failed)
            return
        }
        let line = draft
        // Time-ordered, as binder-v0 §6.2 asks of the message id an op records.
        let requestID = UUID(uuidString: UUIDv7.make()) ?? UUID()
        let entry = Entry(id: requestID, speaker: .person, text: line, state: .sending, requestID: requestID)
        threads[key]?.draft = ""
        threads[key]?.message = nil
        threads[key]?.entries.append(entry)
        await deliver(entry, binder: binder, key: key, folder: folder, through: commands)
    }

    /// Sends a line that was not accepted again, with its first request id.
    func retry(_ entry: Entry) async {
        guard let folder, let commands, let binder = binderID(folder), shown.turn == nil,
              case .notSent = entry.state, entry.speaker == .person else { return }
        let key = key(folder)
        update(entry.id, in: key) { $0.state = .sending }
        await deliver(entry, binder: binder, key: key, folder: folder, through: commands)
    }

    private func deliver(_ entry: Entry, binder: String, key: String, folder: URL, through commands: ChatCommands) async {
        guard let requestID = entry.requestID else { return }
        do {
            let turn = try await commands.send(ChatSendRequest(binderID: binder, requestID: requestID, text: entry.text))
            update(entry.id, in: key) { $0.state = .sent }
            // A line put back in the composer when it was not accepted leaves it once it is, unless typed over since.
            if threads[key]?.restored == entry.requestID {
                threads[key]?.draft = ""
                threads[key]?.restored = nil
            }
            let reply = Entry(id: turn.turnID, speaker: .binder, text: "", state: .replying, requestID: requestID)
            threads[key]?.entries.append(reply)
            threads[key]?.turn = turn.turnID
            Task { await self.follow(turn, reply: reply.id, key: key, folder: folder) }
        } catch {
            update(entry.id, in: key) { $0.state = .notSent(Self.words(error)) }
            if threads[key]?.draft.isEmpty == true {
                threads[key]?.draft = entry.text
                threads[key]?.restored = entry.requestID
            }
        }
    }

    /// Reads a turn's events into its reply until the turn says it finished or failed.
    private func follow(_ turn: ChatTurn, reply: UUID, key: String, folder: URL) async {
        var ended = false
        for await event in turn.events {
            switch event {
            case .textDelta(let piece):
                update(reply, in: key) { entry in
                    guard !entry.cutShort else { return }
                    let room = Self.maximumReplyBytes - entry.text.utf8.count
                    if piece.utf8.count <= room {
                        entry.text += piece
                    } else {
                        // Only what fits is copied, cut at a character's edge, so one huge piece cannot pass the limit.
                        entry.text += Self.prefix(of: piece, bytes: room) + "\n[The rest of this reply is not shown.]"
                        entry.cutShort = true
                    }
                }
            case .activity(let doing):
                update(reply, in: key) { $0.activity = Self.prefix(of: doing, bytes: Self.maximumChangeBytes) }
            case .binderChanged(let change):
                update(reply, in: key) { entry in
                    guard entry.changes.count < Self.maximumChanges else { entry.changesCut = true; return }
                    entry.changes.append(Self.bounded(change))
                }
                changed(folder)
            case .finished(let how):
                update(reply, in: key) { $0.state = how == .replied ? .replied : .stopped }
                ended = true
            case .failed(let failure):
                update(reply, in: key) { $0.state = .failed(Self.words(failure)); $0.problem = ReplyProblem(failure) }
                ended = true
            }
            if ended { break }
        }
        if !ended { update(reply, in: key) { $0.state = .incomplete; $0.problem = .lostTouch } }
        update(reply, in: key) { $0.activity = nil }
        if threads[key]?.turn == turn.turnID {
            threads[key]?.turn = nil
            threads[key]?.stopping = false
        }
    }

    /// What this reply's Notice offers now. Only the last entry of a thread with nothing running offers anything, so an old
    /// failure cannot act on a conversation that has moved on, and words are found by request id, never by position.
    func actions(for entry: Entry) -> [ReplyProblem.Action] {
        guard let problem = entry.problem, shown.entries.last?.id == entry.id, shown.turn == nil else { return [] }
        return problem.actions.filter { action in
            switch action {
            case .editAndSend: line(answeredBy: entry) != nil
            case .checkReply: reattach != nil && line(answeredBy: entry) != nil
            case .openAssistant, .restart: true
            }
        }
    }

    private func line(answeredBy reply: Entry) -> Entry? {
        guard let requestID = reply.requestID else { return nil }
        return shown.entries.first { $0.speaker == .person && $0.requestID == requestID }
    }

    /// Puts the person's words back in the composer, to change or send as a new turn. Never over text already there.
    func putBack(_ entry: Entry) {
        guard let shownKey, actions(for: entry).contains(.editAndSend), let line = line(answeredBy: entry) else { return }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            threads[shownKey]?.message = "The box below already holds text. Send or clear it first."
            return
        }
        threads[shownKey]?.draft = line.text
        threads[shownKey]?.message = nil
    }

    /// Asks the binder how a reply Sprava lost touch with ended; never sends the line again.
    func checkReply(_ entry: Entry) {
        guard let folder, actions(for: entry).contains(.checkReply), let requestID = entry.requestID, let binder = binderID(folder),
              let turn = reattach?(binder, requestID, entry.id, folder) else { return }
        resume(turn, in: folder)
    }

    /// Asks the binder to stop the turn running on the page shown. Changes already made keep their Undo.
    func stop() async {
        guard let folder, let commands, let binder = binderID(folder), let turn = shown.turn, !shown.stopping else { return }
        let key = key(folder)
        threads[key]?.stopping = true
        do {
            try await commands.interrupt(binderID: binder, turnID: turn)
        } catch {
            threads[key]?.stopping = false
            threads[key]?.message = "Could not stop the reply: \(Self.words(error))"
        }
    }

    /// Undoes the changes one reply made, through the binder's owner.
    func undo(_ change: ChatBinderChange) async {
        guard let folder, let reference = change.undo, let undoChange, !isUndone(change) else { return }
        let key = key(folder)
        do {
            try await undoChange(reference, folder)
            threads[key]?.undone.insert(reference.batchID)
            changed(folder)
        } catch {
            threads[key]?.message = "\(error)"
        }
    }

    private func update(_ id: UUID, in key: String, _ change: (inout Entry) -> Void) {
        guard let index = threads[key]?.entries.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[key]!.entries[index])
    }

    /// A change as the page keeps it: its summary cut to its limit, its ids to the reply's, and no Undo for a
    /// reference too long to be a real one.
    static func bounded(_ change: ChatBinderChange) -> ChatBinderChange {
        ChatBinderChange(operationIDs: Array(change.operationIDs.prefix(64)).filter { $0.utf8.count <= maximumChangeBytes },
                         summary: prefix(of: change.summary, bytes: maximumChangeBytes),
                         undo: change.undo.flatMap { $0.batchID.utf8.count <= maximumChangeBytes ? $0 : nil })
    }

    /// The longest start of `text` within `bytes` UTF-8 bytes, cut between characters.
    static func prefix(of text: String, bytes: Int) -> String {
        var used = 0, end = text.startIndex
        for character in text {
            let size = character.utf8.count
            guard used + size <= bytes else { break }
            used += size
            end = text.index(after: end)
        }
        return String(text[..<end])
    }

    static func words(_ error: Error) -> String {
        switch error as? ChatCommandFailure {
        case .invalidRequest?: "This line cannot be sent as it is."
        case .busy?: "The binder is still busy with another reply. Try again in a moment."
        case .unavailable?, nil: "Sprava's background part did not answer. Try again in a moment."
        case .cancelled?: "Sending was cancelled."
        case .turnFailed(let reason, let account)?: words(turnFailure: reason, account: account)
        }
    }

    /// Why Claude's turn did not finish. A code the runtime sends and this build does not know gets the general line.
    static func words(turnFailure reason: String?, account: String? = nil) -> String {
        let named = account.map { "“\($0)”" }
        return switch reason {
        case "busy": "Sprava is still busy with another reply. Try again in a moment."
        case "start_failed": "The assistant could not be started. Try again in a moment."
        case "exit_unconfirmed": "Sprava could not confirm that the assistant stopped, so new messages in this binder wait. Restarting Sprava's background part may clear this."
        case "protocol": "The assistant answered in a way Sprava did not expect, so this reply was stopped. Try again, and if it keeps happening, look at the Assistant page."
        case "authentication": named.map { "Claude rejected the token for \($0). Save a new one in Assistant." } ?? "Claude rejected the sign-in. Check the connection in Assistant."
        case "usage_limit": "\(named.map { "The Claude account \($0)" } ?? "This Claude account") has reached a usage limit. Add another account in Assistant, or try again after it resets."
        case "no_quota": "None of your Claude accounts has quota left right now. Try again after one resets."
        case "token_missing": named.map { "Sprava has no token for \($0). Add one in Assistant." } ?? "Sprava has no token for that Claude account. Add one in Assistant."
        case "engine": "This request could not be finished, which can mean a service problem or a file too large for it. Try again, or ask for less at once."
        case "ended_early": "The reply stopped before it finished. Try again."
        case "output_limit": "The reply was too long to keep. Ask for less at once."
        case "deadline": "This request ran out of time. Ask for less at once."
        case "replacement_required": "This conversation needs a fresh start. Send your message again."
        case "setup": "Claude's setup needs a look. Check the connection in Assistant."
        case "too_large": "This binder and its recent conversation are too much to send in one turn."
        case "binder_unavailable": "The binder could not be reached: it may be offloaded or off the shelf."
        default: "This request could not be finished. It was not retried."
        }
    }

    // MARK: - Saved history

    /// The last months of the binder's saved conversation, display-only (binder-v0 §7.2.1), read off the main actor.
    nonisolated static func history(_ folder: URL) async -> (entries: [Entry], note: String?) {
        let read = Task.detached(priority: .userInitiated) { () -> (entries: [Entry], note: String?) in
            guard case .months(let months) = ConversationHistory.months(in: folder) else {
                return ([], "Earlier messages could not be read; they were left as they are.")
            }
            var entries: [Entry] = [], damaged = false
            for month in months.suffix(historyMonths) {
                guard !Task.isCancelled else { return ([], nil) }
                guard case .month(let read) = ConversationHistory.read(month: month, in: folder) else { damaged = true; continue }
                damaged = damaged || !read.damage.isEmpty
                entries += read.messages.map { message in
                    Entry(id: UUID(), speaker: message.speaker == .person ? .person : .binder, text: message.text, state: .earlier)
                }
            }
            return (entries, damaged ? "Some earlier messages could not be read; they were left as they are." : nil)
        }
        // Leaving the page cancels the read between months, so abandoned pages do not pile up reads.
        return await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
    }
}
