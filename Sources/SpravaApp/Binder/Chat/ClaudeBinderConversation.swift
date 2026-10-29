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
    @Published private(set) var connected = false
    /// Whether Claude is set up in Sprava (Brains): true or false as the runtime said, nil when it could not be asked,
    /// which is no evidence either way.
    @Published private(set) var accountReady: Bool?
    @Published private(set) var busy = false
    @Published var documents = true
    @Published var intake = true
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
    lazy var chat = BinderChat(commands: adapter, binderID: { [weak self] folder in self?.scopes[folder.standardizedFileURL] }, ready: { [weak self] folder in self?.connected == true && self?.folder == folder }, readHistory: { [weak self] folder in
        guard let self else { return ([], "Saved conversation is unavailable.") }
        return await self.history(folder)
    })
    var hasSavedScope: Bool { folder.flatMap { scopes[$0] } != nil }
    init(client: RuntimeClient = RuntimeClient(), authenticate: @escaping () async throws -> Void = {
        guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Share this binder's selected information with Claude.") else { throw CancellationError() }
    }) { self.client = client; self.authenticate = authenticate }

    func show(_ folder: URL) async {
        let folder = folder.standardizedFileURL; self.folder = folder
        do {
            let state = try await client.command("claude_binder", binder: folder)
            guard self.folder == folder else { return }
            connected = state["enabled"] == .bool(true)
            scopes[folder] = state["binder_id"]?.stringValue
            if connected { documents = state["documents"] == .bool(true); intake = state["intake"] == .bool(true) }
            message = nil
        } catch { guard self.folder == folder else { return }; connected = false; scopes[folder] = nil; message = "Sprava could not check this binder's Claude connection. Open Health to check the background part." }
        // A connected binder needs Claude set up; only an unconnected one asks, for what to offer next.
        if connected { accountReady = true } else { await readAccount() }
        await chat.show(folder)
        if self.folder == folder, let turn = pending[folder], turn.binderID == scopes[folder],
           chat.needsResume(requestID: turn.requestID, in: folder) {
            chat.resume(observe(turn, in: folder), in: folder)
        }
    }
    /// Asks the runtime whether Claude is set up in Sprava; a failed read leaves the answer unknown.
    func readAccount() async {
        do { accountReady = try await client.global("claude_status", timeout: 5)["enabled"] == .bool(true) }
        catch { accountReady = nil }
    }

    func connect() async {
        guard !busy, let folder else { return }; busy = true; defer { busy = false }
        do {
            try await authenticate()
        } catch { message = "Connecting needs your Touch ID or login password. Nothing was changed."; return }
        do {
            _ = try await client.command("claude_enable", binder: folder, [("documents", .bool(documents)), ("intake", .bool(intake))], timeout: 30)
            if self.folder == folder { await show(folder) }
        } catch {
            await readAccount()
            message = Self.notConnected(error, accountReady: accountReady)
        }
    }

    /// Why a binder was not connected, naming what to do: the setup in Brains when the runtime says Claude is not set
    /// up, the background part when it could not be asked, and the binder itself otherwise.
    static func notConnected(_ error: Error, accountReady: Bool?) -> String {
        if let failure = error as? RuntimeClient.Failure, failure.kind != .refused {
            return "The binder was not connected: Sprava's background part did not answer. Open Health, then try again."
        }
        switch accountReady {
        case false?: return "The binder was not connected: Claude is not set up in Sprava yet. Open Brains and follow its steps, then connect here."
        case nil: return "The binder was not connected, and Sprava could not check Claude's setup. Open Health, then try again."
        case true?: return "The binder was not connected. Claude is set up; check that this binder is adopted and ready, then try again."
        }
    }
    func disconnect() async {
        guard !busy, let folder else { return }; busy = true; defer { busy = false }
        do { _ = try await client.command("claude_disable", binder: folder, timeout: 30); if self.folder == folder { await show(folder) } }
        catch { message = "The connection could not be changed. Check whether Claude stopped before trying again." }
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
                continuation.yield(.activity("Claude is reading this binder…"))
                defer { continuation.finish() }
                while !Task.isCancelled {
                    do {
                        let value = try await self.client.command("chat_poll", binder: folder, [("request_id", .str(turn.requestID.uuidString))])
                        guard value["turn_id"] == .str(turn.turnID.uuidString), value["binder_id"] == .str(turn.binderID),
                              value["request_id"] == .str(turn.requestID.uuidString) else { throw ChatCommandFailure.unavailable }
                        switch value["phase"]?.stringValue {
                        case "replied":
                            self.forgetPending(turn, in: folder)
                            let body = try self.displayReply(value, turn: turn.turnID, folder: folder, historical: false)
                            continuation.yield(.textDelta(body)); continuation.yield(.finished(.replied)); return
                        case "interrupted": self.forgetPending(turn, in: folder); continuation.yield(.finished(.interrupted)); return
                        case "failed": self.forgetPending(turn, in: folder); continuation.yield(.failed(.unavailable)); return
                        case "accepted", "running": break
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
    private func forgetPending(_ turn: SavedTurn, in folder: URL) {
        if pending[folder]?.turnID == turn.turnID { pending[folder] = nil }
    }
    private func interrupt(binder: String, turn: UUID) async throws {
        guard let folder = scopes.first(where: { $0.value == binder })?.key, let request = requests[turn] else { throw ChatCommandFailure.unavailable }
        _ = try await client.command("chat_stop", binder: folder, [("request_id", .str(request.uuidString)), ("turn_id", .str(turn.uuidString))], timeout: 30)
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
            cards[id]?.saved = true; cards[id]?.message = "Added privately to this binder and the global To-dos list."
        } catch let failure as RuntimeClient.Failure where failure.kind == .timedOut || failure.kind == .notRunning {
            cards[id]?.uncertain = true; cards[id]?.message = "The save could not be confirmed. Check To-dos before adding another copy; this action will not retry automatically."
        } catch { cards[id]?.message = "The task could not be added. Its text is kept here." }
        changed()
    }
}
