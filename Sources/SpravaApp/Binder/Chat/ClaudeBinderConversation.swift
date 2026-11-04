import AppKit
import BinderFormat
import Combine
import Foundation
import LocalAuthentication
import Services
import Shelf
import SpravaKit

/// The real app adapter. Accepted turns outlive polling subscriptions; only Stop requests an interrupt.
/// Cards are editable display suggestions. Saving a task is an explicit ordinary app writer action.
@MainActor
final class ClaudeBinderConversation: ObservableObject, DraftOwner {
    struct TaskDraft: Equatable {
        let title: String?
        let details: String
        let due: String
        let priority: String
    }
    struct Card: Identifiable {
        let id: UUID
        var binder: URL
        let scopeID: String
        var taskTitle: String?
        var taskDetails = ""
        var due = ""
        var priority = "normal"
        var to: String?
        var subject = ""
        var body = ""
        var recipientGrounded = false
        var historical = false
        var saving = false
        var saved = false
        var uncertain = false
        var message: String?
        var citations: [JSONValue] = []
        var originalTask: TaskDraft?
        var taskDraft: TaskDraft { TaskDraft(title: taskTitle, details: taskDetails, due: due, priority: priority) }
    }
    @Published var askToClear = false
    /// Whether this binder's session has grown long enough to suggest a new conversation.
    @Published private(set) var conversationLong = Set<URL>()
    /// The transcript the last New conversation filed, to link to.
    @Published private(set) var filedTranscript: FiledTranscript?
    struct FiledTranscript: Equatable { let folder: URL; let path: String }
    @Published private(set) var startingNew = false
    /// Whether a connected binder's sharing details are showing.
    @Published private(set) var checking = false
    /// Why the binder shown is not connected, as the runtime said. Nil when the runtime did not answer.
    @Published private(set) var notConnectedReason: String?
    @Published private(set) var runtimeAnswered = true
    @Published private(set) var connected = false
    /// Whether Claude is set up in Sprava (Brains): true or false as the runtime said, nil when it could not be asked,
    /// which is no evidence either way.
    @Published private(set) var accountReady: Bool?
    @Published private(set) var busy = false
    @Published var documents = true
    @Published var intake = true
    /// Lets Claude change and delete this binder's files. Its tools can read the whole folder, so it needs both sharing choices.
    @Published var files = true
    var allowsFiles: Bool { files && documents && intake }
    @Published private(set) var message: String?
    @Published var cards: [UUID: Card] = [:]
    private var scopes: [URL: String] = [:]
    private var requests: [UUID: UUID] = [:]
    private struct SavedTurn {
        let binderID: String
        let requestID: UUID
        let turnID: UUID
    }
    private var pending: [URL: SavedTurn] = [:]
    private(set) var folder: URL?
    let client: RuntimeClient
    let authenticate: () async throws -> Void
    var changed: () -> Void = {}
    var draftState: DraftState {
        chat.draftState.merging(DraftState(hasChanges: cards.values.contains { !$0.saved && $0.originalTask != nil && $0.taskDraft != $0.originalTask },
                                           saving: cards.values.contains { $0.saving }))
    }
    private lazy var adapter = ChatCommands(send: { [weak self] request in
        guard let self else { throw ChatCommandFailure.unavailable }
        return try await self.send(request)
    }, interrupt: { [weak self] binder, turn in
        guard let self else { throw ChatCommandFailure.unavailable }
        try await self.interrupt(binder: binder, turn: turn)
    })
    lazy var chat: BinderChat = makeChat()
    private func makeChat() -> BinderChat {
        let chat = BinderChat(commands: adapter, binderID: { [weak self] folder in self?.scopes[folder.standardizedFileURL] }, ready: { [weak self] folder in self?.connected == true && self?.folder == folder }, undo: { [weak self] reference, folder in
        guard let self else { throw ChatCommandFailure.unavailable }
        try await self.undoTurn(reference, in: folder)
    }, readHistory: { [weak self] folder in
        guard let self else { return ([], "Saved conversation is unavailable.") }
        return await self.history(folder)
    })
        chat.reattach = { [weak self] binderID, requestID, turnID, folder in
            guard let self else { return ChatTurn(binderID: binderID, requestID: requestID, turnID: turnID, events: AsyncStream { $0.finish() }) }
            return self.observe(SavedTurn(binderID: binderID, requestID: requestID, turnID: turnID), in: folder)
        }
        return chat
    }
    lazy var sharing = ConversationSharing(client: client)
    var scopeID: String? { folder.flatMap { scopes[$0] } }
    var hasSavedScope: Bool { folder.flatMap { scopes[$0] } != nil }
    init(client: RuntimeClient = RuntimeClient(), authenticate: @escaping () async throws -> Void = {
        guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Share this binder's selected information with Claude.") else { throw CancellationError() }
    }) { self.client = client; self.authenticate = authenticate }

    func show(_ folder: URL) async {
        let folder = folder.standardizedFileURL
        self.folder = folder
        checking = true; defer { if self.folder == folder { checking = false } }
        do {
            let state = try await client.command("claude_binder", binder: folder)
            guard self.folder == folder else { return }
            connected = state["enabled"] == .bool(true)
            scopes[folder] = state["binder_id"]?.stringValue
            notConnectedReason = state["reason"]?.stringValue
            runtimeAnswered = true
            if connected { documents = state["documents"] == .bool(true); intake = state["intake"] == .bool(true); files = state["files"] == .bool(true) }
            message = nil
        } catch { guard self.folder == folder else { return }; connected = false; scopes[folder] = nil; notConnectedReason = nil; runtimeAnswered = false; message = nil }
        // A connected binder needs Claude set up; only an unconnected one asks, for what to offer next. Another binder
        // shown meanwhile owns the page from then on, its conversation included.
        let ready = connected ? true : await accountStatus()
        guard self.folder == folder else { return }
        accountReady = ready
        await chat.show(folder)
        if self.folder == folder, let turn = pending[folder], turn.binderID == scopes[folder],
           chat.needsResume(requestID: turn.requestID, in: folder) {
            chat.resume(observe(turn, in: folder), in: folder)
        }
    }
    var connectionState: ConnectionState {
        ConnectionState(runtimeAnswered: runtimeAnswered, accountReady: accountReady, reason: notConnectedReason)
    }
    /// Asks the runtime whether Claude is set up in Sprava; nil when it could not be asked.
    func accountStatus() async -> Bool? {
        do { return try await client.global("claude_status", timeout: 5)["enabled"] == .bool(true) }
        catch { return nil }
    }

    func connect() async {
        guard !busy, let folder else { return }; busy = true; defer { busy = false }
        // Each outcome is reported only while its binder is still the one shown.
        do {
            try await authenticate()
        } catch {
            if self.folder == folder { message = "Connecting needs your Touch ID or login password. Nothing was changed." }
            return
        }
        do {
            _ = try await client.command("claude_enable", binder: folder, [("documents", .bool(documents)), ("intake", .bool(intake)), ("files", .bool(allowsFiles))], timeout: 30)
            if self.folder == folder { await show(folder) }
        } catch {
            let ready = await accountStatus()
            guard self.folder == folder else { return }
            accountReady = ready
            message = Self.notConnected(error, accountReady: ready)
        }
    }

    /// Why a binder was not connected, naming what to do: the setup in Brains when the runtime says Claude is not set
    /// up, the background part when it could not be asked, and the binder itself otherwise.
    static func notConnected(_ error: Error, accountReady: Bool?) -> String {
        if let failure = error as? RuntimeClient.Failure, failure.kind != .refused {
            return "The binder was not connected: Sprava's background part did not answer. Open Health, then try again."
        }
        switch accountReady {
        case false?: return "The binder was not connected: Claude is not set up in Sprava yet. Open Assistant and follow its steps, then connect here."
        case nil: return "The binder was not connected, and Sprava could not check Claude's setup. Open Health, then try again."
        case true?: return "The binder was not connected. Claude is set up; check that this binder is adopted and ready, then try again."
        }
    }
    func disconnect() async {
        guard !busy, let folder else { return }; busy = true; defer { busy = false }
        do { _ = try await client.command("claude_disable", binder: folder, timeout: 30); if self.folder == folder { await show(folder) } }
        catch { message = "The connection could not be changed. Check whether the reply stopped before trying again." }
    }
    func clear() async {
        guard !busy, let folder else { return }; busy = true; defer { busy = false }
        do {
            _ = try await client.command("chat_clear", binder: folder, timeout: 30)
            cards = cards.filter { $0.value.binder != folder }
            pending[folder] = nil
            chat.forgetHistory(folder)
            if self.folder == folder { await show(folder) }
        } catch { message = "The saved conversation could not be cleared. Nothing was reported as cleared." }
    }

    /// Turns the page: Claude brings the Notes up to date if it can, the transcript is filed in the binder, and only then the session ends
    /// and the screen clears. If filing fails, nothing is cleared.
    func startNewConversation() async {
        guard !busy, !startingNew, let folder, let scope = scopeID else { return }
        startingNew = true; defer { startingNew = false }
        do {
            message = "Bringing the notes up to date…"
            let settled: String
            do {
                let closing = try await client.command("chat_closing_notes", binder: folder, [("request_id", .str(UUID().uuidString))], timeout: 150)
                guard let state = closing["settled"]?.stringValue else { throw ChatCommandFailure.unavailable }
                settled = state
            } catch {
                message = "Wait for the reply to finish, then try again. Nothing was cleared."
                return
            }
            // The chat holds only the page in view. Another binder's page means this one's unsent lines cannot be read, so nothing goes further.
            guard Self.canFile(folder, selected: self.folder, inChat: chat.folder) else {
                message = nil
                return
            }
            message = "Filing this conversation in the binder…"
            let text = try await sharing.transcript(folder: folder, scope: scope, entries: chat.entries, cards: cards.filter { $0.value.binder == folder })
            let answer = try await client.command("chat_file_and_clear", binder: folder, [("text", .str(text)), ("settled", .str(settled))], timeout: 60)
            guard let path = answer["path"]?.stringValue else { throw ChatCommandFailure.unavailable }
            cards = cards.filter { $0.value.binder != folder }
            pending[folder] = nil
            chat.forgetHistory(folder)
            conversationLong.remove(folder)
            filedTranscript = FiledTranscript(folder: folder, path: path)
            message = nil
            changed()
            if self.folder == folder { await show(folder) }
        } catch {
            message = "This conversation could not be filed, so it stays as it is. Nothing was cleared."
        }
    }
    static func canFile(_ folder: URL, selected: URL?, inChat: URL?) -> Bool { selected == folder && inChat == folder }
    func openFiledTranscript() {
        guard let filed = filedTranscript else { return }
        NSWorkspace.shared.open(filed.folder.appendingPathComponent(filed.path))
    }

    private func send(_ request: ChatSendRequest) async throws -> ChatTurn {
        guard let folder = scopes.first(where: { $0.value == request.binderID })?.key else { throw ChatCommandFailure.unavailable }
        let accepted = try await client.command("chat_send", binder: folder, [("request_id", .str(request.requestID.uuidString)), ("text", .str(request.text))], timeout: 45)
        guard accepted["binder_id"] == .str(request.binderID), accepted["request_id"] == .str(request.requestID.uuidString),
              let turn = accepted["turn_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw ChatCommandFailure.unavailable }
        let saved = SavedTurn(binderID: request.binderID, requestID: request.requestID, turnID: turn)
        pending[folder] = saved
        return observe(saved, in: folder)
    }

    private func observe(_ turn: SavedTurn, in folder: URL) -> ChatTurn {
        requests[turn.turnID] = turn.requestID
        let events = AsyncStream<ChatReplyEvent> { continuation in
            let polling = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                let began = ContinuousClock.now
                var shown = Self.activityLine(doing: nil, steps: 0, elapsed: .zero)
                continuation.yield(.activity(shown))
                defer { continuation.finish() }
                while !Task.isCancelled {
                    do {
                        let value = try await self.client.command("chat_poll", binder: folder, [("request_id", .str(turn.requestID.uuidString))])
                        guard value["turn_id"] == .str(turn.turnID.uuidString), value["binder_id"] == .str(turn.binderID),
                              value["request_id"] == .str(turn.requestID.uuidString) else { throw ChatCommandFailure.unavailable }
                        if value["conversation_long"] == .bool(true) { self.conversationLong.insert(folder) }
                        switch value["phase"]?.stringValue {
                        case "replied":
                            self.forgetPending(turn, in: folder)
                            let body = try self.displayReply(value, turn: turn.turnID, folder: folder, historical: false)
                            continuation.yield(.textDelta(body))
                            if let change = Self.change(value, turn: turn.turnID) { continuation.yield(.binderChanged(change)); self.changed() }
                            continuation.yield(.finished(.replied)); return
                        case "interrupted":
                            self.forgetPending(turn, in: folder)
                            if let change = Self.change(value, turn: turn.turnID) { continuation.yield(.binderChanged(change)); self.changed() }
                            continuation.yield(.finished(.interrupted)); return
                        case "failed":
                            self.forgetPending(turn, in: folder)
                            if let change = Self.change(value, turn: turn.turnID) { continuation.yield(.binderChanged(change)); self.changed() }
                            continuation.yield(.failed(.turnFailed(value["reason"]?.stringValue, account: value["account"]?.stringValue))); return
                        case "accepted", "running":
                            let line = Self.activityLine(doing: value["activity"]?.stringValue,
                                                         steps: value["steps"]?.numberValue?.safeInteger.map { Int(clamping: $0) } ?? 0,
                                                         elapsed: began.duration(to: .now))
                            if line != shown { shown = line; continuation.yield(.activity(line)) }
                        default: throw ChatCommandFailure.unavailable
                        }
                        try await Task.sleep(for: .milliseconds(750))
                    } catch is CancellationError { return }
                    catch { continuation.yield(.failed(.unavailable)); return }
                }
            }
            continuation.onTermination = { _ in polling.cancel() } // Never Stop on lost subscription.
        }
        return ChatTurn(binderID: turn.binderID, requestID: turn.requestID, turnID: turn.turnID, events: events)
    }
    /// The one line a running turn shows, replaced as it goes and gone when the reply comes. A turn has no known length, so
    /// it says what is happening and how far it has come, not a share of a whole.
    nonisolated static func activityLine(doing: String?, steps: Int, elapsed: Duration) -> String {
        var line = doing ?? "Starting\u{2026}"
        if steps > 0 { line += " \u{00B7} \(steps) step\(steps == 1 ? "" : "s")" }
        let minutes = Int(elapsed.components.seconds / 60)
        if minutes > 0 { line += " \u{00B7} \(minutes) min" }
        return line
    }
    private func forgetPending(_ turn: SavedTurn, in folder: URL) {
        if pending[folder]?.turnID == turn.turnID { pending[folder] = nil }
    }
    private func interrupt(binder: String, turn: UUID) async throws {
        guard let folder = scopes.first(where: { $0.value == binder })?.key, let request = requests[turn] else { throw ChatCommandFailure.unavailable }
        _ = try await client.command("chat_stop", binder: folder, [("request_id", .str(request.uuidString)), ("turn_id", .str(turn.uuidString))], timeout: 30)
    }
    /// The line a turn left, with its Undo; one already undone says so and offers nothing more.
    static func change(_ value: JSONObject, turn: UUID) -> ChatBinderChange? {
        guard let summary = value["changes"]?["summary"]?.stringValue else { return nil }
        if value["changes"]?["undone"] == .bool(true) { return ChatBinderChange(operationIDs: [], summary: summary + " (undone)", undo: nil) }
        if value["changes"]?["undoable"] == .bool(false) { return ChatBinderChange(operationIDs: [], summary: summary, undo: nil) }
        return ChatBinderChange(operationIDs: [], summary: summary, undo: ChatUndoReference(batchID: turn.uuidString))
    }

    struct UndoRefused: Error, CustomStringConvertible { let description: String }

    private func undoTurn(_ reference: ChatUndoReference, in folder: URL) async throws {
        guard let turn = UUID(uuidString: reference.batchID) else { throw UndoRefused(description: "This change can no longer be undone.") }
        let value: JSONObject
        do { value = try await client.command("chat_undo", binder: folder, [("turn_id", .str(turn.uuidString))], timeout: 120) }
        catch { throw UndoRefused(description: "Undo did not complete. Nothing is reported as undone; check the binder's folder.") }
        guard value["undone"] == .bool(true) else {
            if value["records_changed"] == .bool(true) {
                throw UndoRefused(description: "Nothing was undone: something was filed or approved during that turn. Use Undo under Recent changes for that, and change the files by hand.")
            }
            if let left = value["todos_left"]?.arrayValue {
                changed() // Everything else was undone.
                let names = left.compactMap(\.stringValue).prefix(5).joined(separator: ", ")
                let notes = value["notes_left"] == .bool(true) ? "The notes changed after that turn, so they stay as they are. " : ""
                throw UndoRefused(description: notes + (names.isEmpty ? "" : "These to-dos changed after that turn, so they stay as they are: \(names). ") + "Everything else was undone.")
            }
            let names = (value["conflicts"]?.arrayValue ?? []).compactMap(\.stringValue).prefix(5).joined(separator: ", ")
            throw UndoRefused(description: "Nothing was undone: \(names.isEmpty ? "these files" : names) changed after that turn.")
        }
        changed()
    }

    private func history(_ folder: URL) async -> (entries: [BinderChat.Entry], note: String?) {
        do {
            let value = try await client.command("chat_history", binder: folder)
            var entries: [BinderChat.Entry] = []
            for row in value["turns"]?.arrayValue ?? [] {
                guard let request = row["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)), let turn = row["turn_id"]?.stringValue.flatMap(UUID.init(uuidString:)), let text = row["text"]?.stringValue else { continue }
                entries.append(.init(id: request, speaker: .person, text: text, state: .earlier, requestID: request))
                if ["accepted", "running"].contains(row["phase"]?.stringValue ?? ""),
                   let binder = row["binder_id"]?.stringValue, binder == scopes[folder] {
                    pending[folder] = SavedTurn(binderID: binder, requestID: request, turnID: turn)
                } else if pending[folder]?.turnID == turn { pending[folder] = nil }
                if row["phase"] == .str("replied"), let object = row.objectValue {
                    entries.append(.init(id: turn, speaker: .binder, text: try displayReply(object, turn: turn, folder: folder, historical: true), state: .earlier))
                } else if ["failed", "interrupted"].contains(row["phase"]?.stringValue ?? "") {
                    entries.append(.init(id: turn, speaker: .binder, text: "This earlier request did not complete. It was not retried automatically.", state: .earlier))
                }
                if entries.last?.id == turn, let object = row.objectValue, let change = Self.change(object, turn: turn) {
                    entries[entries.count - 1].changes = [change]
                }
            }
            return (entries, value["more"] == .bool(true) ? "Showing the latest saved messages." : nil)
        } catch { return ([], "Saved conversation could not be read; it was left as it is.") }
    }
    private func displayReply(_ value: JSONObject, turn: UUID, folder: URL, historical: Bool) throws -> String {
        guard let raw = value["reply"]?.stringValue, let parsed = try? JSONParser.parse(raw), parsed.safety.isSafe,
              let answer = parsed.value["answer"]?.stringValue else { throw ChatCommandFailure.unavailable }
        let data = parsed.value
        if cards[turn] == nil {
            cards[turn] = Card(id: turn, binder: folder, scopeID: value["binder_id"]?.stringValue ?? scopes[folder] ?? "", taskTitle: data["task"]?["title"]?.stringValue,
                taskDetails: data["task"]?["details"]?.stringValue ?? "", to: data["draft"]?["to"]?.stringValue,
                subject: data["draft"]?["subject"]?.stringValue ?? "", body: data["draft"]?["body"]?.stringValue ?? "",
                recipientGrounded: data["draft"]?["recipient_in_sources"] == .bool(true), historical: historical)
            cards[turn]?.citations = data["citations"]?.arrayValue ?? []
            cards[turn]?.due = data["task"]?["due"]?.stringValue ?? ""
            cards[turn]?.priority = data["task"]?["priority"]?.stringValue ?? "normal"
            let original = cards[turn]?.taskDraft
            cards[turn]?.originalTask = original
        }
        if cards[turn]?.scopeID == scopes[folder] { cards[turn]?.binder = folder }
        let citations = (data["citations"]?.arrayValue ?? []).compactMap { citation -> String? in
            guard let path = citation["path"]?.stringValue else { return nil }
            return path + (citation["page"]?.numberValue?.safeInteger.map { ", page \($0)" } ?? "")
        }
        return answer + (citations.isEmpty ? "" : "\n\nSources:\n" + citations.joined(separator: "\n"))
    }

    func addTask(_ id: UUID) async {
        guard var card = cards[id], !card.saving, !card.saved, !card.uncertain,
              let title = card.taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, scopes[card.binder] == card.scopeID else { return }
        card.saving = true; cards[id] = card
        defer { cards[id]?.saving = false }
        guard title.utf8.count <= 4_096, card.taskDetails.utf8.count <= 32_768,
              card.due.isEmpty || CalendarDate.strict(card.due) != nil else {
            cards[id]?.message = "Keep the task within the text limits and use YYYY-MM-DD for a due date, or leave it blank."; return
        }
        var fields: [(String, JSONValue)] = [("id", .str("$new:1")), ("title", .str(title)), ("notes", .str(card.taskDetails)),
                                   ("status", .str("open")), ("priority", .str(card.priority)), ("sensitivity", .str("private"))]
        fields.append(card.due.isEmpty ? ("no_deadline", .bool(true)) : ("due", .str(card.due)))
        let item: JSONValue = .obj(fields)
        do {
            let result = try await client.command("apply", binder: card.binder, [("op", .str("add_item")), ("args", .obj([("item", item)])), ("conversation_binding", .str(card.scopeID))])
            guard let op = result["op"]?.stringValue, !op.isEmpty else {
                cards[id]?.uncertain = true; cards[id]?.message = "The save returned no confirmation. Check To-dos before adding another copy."; changed(); return
            }
            cards[id]?.saved = true; cards[id]?.message = "Added privately to this binder and to Today."
        } catch let failure as RuntimeClient.Failure where failure.kind == .timedOut || failure.kind == .notRunning {
            cards[id]?.uncertain = true; cards[id]?.message = "The save could not be confirmed. Check To-dos before adding another copy; this action will not retry automatically."
        } catch { cards[id]?.message = "The task could not be added. Its text is kept here." }
        changed()
    }
}
