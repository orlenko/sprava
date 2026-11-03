import BinderStore
import Backup
import Shelf
import Brains
import Darwin
import Foundation
import Retrieval
import SpravaKit

/// One app-authenticated, explicitly consented conversation per physical binder. Its file tools stop at the binder's
/// folder, and the only operations it can reach are the to-do tools of a person's own turn (`ClaudeTodoTools`).
public actor ClaudeConversationRuntime {
    public enum Refused: Error, Sendable { case notConnected, busy, unavailable, invalidRequest, stopped, tooLarge }
    struct Driver: Sendable {
        let run: @Sendable (String, Bool) async throws -> String?
        let stop: @Sendable () -> Void
        let exited: @Sendable () -> Bool
        let hash: String
    }
    struct Secrets: Sendable {
        let read: @Sendable () throws -> String?
        let replace: @Sendable (String?) throws -> Void
        var persistent: @Sendable () -> Bool = { true }
    }
    typealias MakeDriver = @Sendable (URL, String, UUID, UUID, String, URL?, ClaudeAppTools?, @escaping @Sendable (Int32) throws -> Void) async throws -> Driver
    typealias ReadContext = @Sendable (URL, Bool, Bool, String, @escaping @Sendable () -> Bool) throws -> ClaudeBinderContext
    typealias SearchBinder = @Sendable (URL, String, Int, @escaping @Sendable () -> Bool) throws -> ClaudeBinderContext.Found
    /// The binder writer the to-do tools go through. The runtime attaches it at start.
    public nonisolated let todoWriter = ClaudeTodoWriter()
    /// Why a turn failed, for as long as this process runs; a failed turn from before a restart has no reason to give.
    private var failureReasons: [UUID: String] = [:]
    private let support: URL
    private let connections: ClaudeReadConnections
    private var exports = ConversationExport()
    private let receipts: ConversationTurnStore
    private let state: ClaudeConversationState
    private let secrets: Secrets
    private let makeDriver: MakeDriver
    private let readContext: ReadContext
    private let searchBinder: SearchBinder
    private let admission: AgentSessionAdmission
    private let available: @Sendable (URL) throws -> Bool
    private var lifecycleTicket: UUID?
    private final class StopSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func stop() { lock.withLock { value = true } }
        var stopped: Bool { lock.withLock { value } }
    }
    private struct Active {
        let request: UUID; let turn: UUID; let signal: StopSignal; let task: Task<Void, Never>
        var driver: Driver?
        var indexing = true
    }
    private var active: [UUID: Active] = [:]
    private var preparing = Set<UUID>()
    private var configuring = false
    private var recovered = false

    init(support: URL, secrets: Secrets, makeDriver: @escaping MakeDriver, context: @escaping ReadContext,
         search: @escaping SearchBinder = { _, _, _, _ in .init(sources: [], incomplete: 0) }, available: @escaping @Sendable (URL) throws -> Bool = { _ in true }) throws {
        self.support = support; self.available = available; self.secrets = secrets; self.makeDriver = makeDriver; readContext = context; searchBinder = search
        connections = try ClaudeReadConnections(at: support.appendingPathComponent("brains/read-scopes.sqlite"))
        receipts = try ConversationTurnStore(at: support.appendingPathComponent("binder-store/conversation.sqlite"))
        state = try ClaudeConversationState(at: support.appendingPathComponent("runtime/claude.sqlite"))
        admission = try AgentSessionAdmission(conversationLimit: 1, taskLimit: 1)
    }

    /// Production registration is explicit in the runtime. Initializing this owner opens only Sprava
    /// state; it does not read Keychain, launch a model, discover binders or enable a backend by itself.
    public static func production(support: URL) throws -> ClaudeConversationRuntime {
        try Self(support: support, secrets: ClaudeSubscriptionSecrets.keychain,
                 makeDriver: { program, credential, connection, session, policy, binder, appTools, onSpawn in
            try await ClaudeNativeConversation.driver(program: program, support: support, credential: credential, connection: connection,
                                                      session: session, policy: policy, binder: binder, appTools: appTools, onSpawn: onSpawn)
        }, context: { folder, documents, intake, query, cancelled in
            try ClaudeBinderContext.build(folder: folder, support: support, documents: documents, intake: intake,
                                          query: query, reader: HelperDocumentReader(binder: folder, reader: .located()), cancelled: cancelled)
        }, search: { folder, query, limit, cancelled in
            try ClaudeBinderContext.search(folder: folder, support: support, query: query, limit: limit,
                                           reader: HelperDocumentReader(binder: folder, reader: .located()), cancelled: cancelled)
        }, available: { folder in
            let path = folder.resolvingSymlinksInPath().path
            let shelf = ShelfStore(supportDirectory: support)
            let picked = try shelf.readFolders()
            let registered = try shelf.registryForShelf()?.entries.filter { !$0.archived }.compactMap { $0.workingDir }.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            } ?? []
            let listed = (picked + registered).contains { $0.resolvingSymlinksInPath().path == path }
            let offloading = try BackupRequests(support: support).all().contains {
                $0.kind == "offload" && $0.binder == path && ["queued", "running", "waiting_for_icloud"].contains($0.state)
            }
            return listed && !offloading
        })
    }

    public static let commands: Set<String> = ["claude_status", "claude_configure", "claude_disconnect", "claude_binder", "claude_enable", "claude_disable", "chat_send", "chat_poll", "chat_history", "chat_export", "chat_undo", "chat_stop", "chat_clear"]

    public func respond(_ text: String) async -> String {
        guard text.utf8.count <= 5 * 1024 * 1024,
              let parsed = try? JSONParser.parse(text), parsed.safety.isSafe,
              let object = parsed.value.objectValue else { return Self.failure("The conversation request is invalid.") }
        do {
            let result = try await handle(object)
            var envelope = JSONObject([(key: "ok", value: .bool(true))])
            for entry in result.entries where entry.key != "ok" && entry.key != "error" { envelope.set(entry.key, entry.value) }
            return JSONWriter.compact(.object(envelope))
        } catch let issue as ClaudeSetupFailure { return Self.failure(issue.message, code: issue.rawValue) }
        catch Refused.notConnected { return Self.failure("Set up Claude in Assistant, then connect this binder.") }
        catch Refused.busy { return Self.failure("Claude is busy. Keep this draft and try again when it finishes.") }
        catch Refused.invalidRequest { return Self.failure("The conversation request is invalid.") }
        catch { return Self.failure("Claude could not complete this request. Check the connection and saved conversation before retrying.") }
    }
    private static func failure(_ message: String, code: String? = nil) -> String {
        JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str(message)), ("code", code.map(JSONValue.str) ?? .null)]))
    }

    /// The XPC listener routes these only after verifying Sprava's app signature. MCP/CLI never get
    /// this handler. All error envelopes are fixed text; no provider output, credentials or source text.
    public func handle(_ request: JSONObject) async throws -> JSONObject {
        try await recover()
        guard let command = request["command"]?.stringValue, Self.commands.contains(command) else { throw Refused.invalidRequest }
        if command == "claude_status" {
            let enabled = try state.account() != nil && secrets.read() != nil
            return .init([(key: "enabled", value: .bool(enabled)), (key: "credential_persistent", value: .bool(secrets.persistent()))])
        }
        if command == "claude_configure" {
            guard let path = request["program"]?.stringValue, path.hasPrefix("/"), let credential = request["credential"]?.stringValue else { throw Refused.invalidRequest }
            try await configure(program: URL(fileURLWithPath: path), credential: credential)
            return .init()
        }
        if command == "claude_disconnect" {
            guard !configuring, preparing.isEmpty else { throw Refused.busy }
            configuring = true; defer { configuring = false }
            try await stopAll()
            try state.setAccount(nil); try secrets.replace(nil); try connections.disableAll()
            return .init()
        }
        guard !configuring, let path = request["binder"]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else { throw Refused.invalidRequest }
        let folder = URL(fileURLWithPath: path)
        if command == "claude_enable" {
            guard try state.account() != nil, try secrets.read() != nil, try available(folder) else { throw Refused.notConnected }
            guard preparing.isEmpty else { throw Refused.busy }
            configuring = true; defer { configuring = false }
            try await stopAll()
            let scope = try connections.enable(folder: folder, documents: request["documents"] == .bool(true), intake: request["intake"] == .bool(true), files: request["files"] == .bool(true))
            try await fence(scope.id)
            return scopeJSON(scope)
        }
        if command == "claude_binder" {
            let id = try connections.savedID(for: folder)
            let current: ClaudeReadConnections.Connection?
            var moved = false
            do { current = try connections.connection(for: folder) }
            catch ClaudeReadConnections.Refused.changed { current = nil; moved = true }
            if let current, try state.account() != nil, try secrets.read() != nil, try available(folder) { return scopeJSON(current) }
            // A fixed word for the app to explain the state with. Whether Claude is set up is claude_status's answer.
            let reason = (try? available(folder)) != true ? "unavailable" : moved ? "moved" : id != nil ? "disconnected" : "new"
            return .init([(key: "enabled", value: .bool(false)), (key: "binder_id", value: id.map { .str($0.uuidString) } ?? .null),
                          (key: "reason", value: .str(reason))])
        }
        if command == "chat_export" {
            guard let id = try connections.savedID(for: folder) else { throw Refused.notConnected }
            return try exports.page(request, binder: id, store: receipts)
        }
        if command == "chat_undo" {
            guard let id = try connections.savedID(for: folder), let turn = request["turn_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw Refused.invalidRequest }
            guard active[id] == nil, !preparing.contains(id), try available(folder) else { throw Refused.busy }
            preparing.insert(id); defer { preparing.remove(id) }
            let history = TurnHistory(support: support, binder: id), writer = todoWriter
            return try await Task.detached(priority: .userInitiated) { () throws -> JSONObject in
                // Files first, whole or not at all. Only then the to-dos, each on its own: one changed since stays as it is, and is named.
                let todos = try history.todoChanges(forTurn: turn), notes = try history.notesChange(forTurn: turn)
                let files = try history.entry(forTurn: turn)
                if (todos == nil && notes == nil) || files?.unrecorded == false {
                    switch try history.undo(turn: turn, in: folder) {
                    case .undone: break
                    case .conflict(let paths): return .init([(key: "undone", value: .bool(false)), (key: "conflicts", value: .array(paths.prefix(20).map { .str($0) }))])
                    case .recordsChanged: return .init([(key: "undone", value: .bool(false)), (key: "records_changed", value: .bool(true))])
                    }
                }
                let left = todos == nil ? [] : try ClaudeTodoTools.undo(turn: turn, folder: folder, history: history, writer: writer)
                let notesBack = try ClaudeTodoTools.undoNotes(turn: turn, folder: folder, history: history, writer: writer)
                if left.isEmpty, notesBack { return .init([(key: "undone", value: .bool(true))]) }
                return .init([(key: "undone", value: .bool(false)), (key: "todos_left", value: .array(left.prefix(20).map { .str($0) })), (key: "notes_left", value: .bool(!notesBack))])
            }.value
        }
        if command == "chat_history" || command == "chat_clear" {
            guard let id = try connections.savedID(for: folder) else { return .init([(key: "turns", value: .array([]))]) }
            if command == "chat_clear" {
                configuring = true; defer { configuring = false }
                try await fence(id); try receipts.clear(conversationID: id); return .init()
            }
            let records = try receipts.history(conversationID: id)
            var chosen: [JSONValue] = [], bytes = 0
            for record in records.reversed().prefix(100) {
                let value = recordJSON(record), count = JSONWriter.compact(value).utf8.count
                if bytes + count > 8 * 1024 * 1024 { break }; bytes += count; chosen.append(value)
            }
            return .init([(key: "turns", value: .array(chosen.reversed())), (key: "more", value: .bool(chosen.count < records.count))])
        }
        if command == "chat_poll" {
            guard let id = try connections.savedID(for: folder),
                  let requestID = request["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let record = try receipts.record(conversationID: id, requestID: requestID) else { throw Refused.invalidRequest }
            return recordJSON(record).objectValue!
        }
        guard let scope = try connections.connection(for: folder) else { throw Refused.notConnected }
        _ = try currentFolder(scope)
        if command == "claude_disable" { configuring = true; defer { configuring = false }; try await fence(scope.id); try connections.disable(scope); return .init() }
        guard let requestID = request["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw Refused.invalidRequest }
        if command == "chat_send" {
            guard let text = request["text"]?.stringValue, request["attachments"] == nil || request["attachments"] == .array([]) else { throw Refused.invalidRequest }
            return recordJSON(try await send(scope: scope, requestID: requestID, text: text)).objectValue!
        }
        guard let record = try receipts.record(conversationID: scope.id, requestID: requestID) else { throw Refused.invalidRequest }
        if command == "chat_stop" {
            guard request["turn_id"]?.stringValue.flatMap(UUID.init(uuidString:)) == record.turnID else { throw Refused.invalidRequest }
            if let current = active[scope.id], current.turn == record.turnID {
                current.signal.stop(); current.driver?.stop()
                if current.indexing {
                    // A sandboxed document reader may finish the file it already received. No more
                    // sources are read and no model is started; its slot stays held until it finishes.
                    _ = try receipts.finish(conversationID: scope.id, requestID: requestID, phase: .interrupted)
                } else {
                    await current.task.value
                    guard current.driver?.exited() != false, active[scope.id] == nil else { throw Refused.unavailable }
                }
            } else if preparing.contains(scope.id) { throw Refused.busy }
            return .init()
        }
        return recordJSON(record).objectValue!
    }

    private func configure(program: URL, credential: String) async throws {
        guard !configuring, active.isEmpty, preparing.isEmpty else { throw Refused.busy }
        let credential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, credential.utf8.count <= 16_384,
              !credential.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { throw ClaudeSetupFailure.tokenFormat }
        configuring = true; defer { configuring = false }
        let id = UUID()
        let firstSession = try state.session(connection: id, generation: UUID(), hash: "setup")
        var recorded = firstSession
        var driver: Driver?
        let question = Self.setupQuestion
        var stage = ClaudeSetupFailure.firstReply
        do {
            let first = try await makeDriver(program, credential, id, firstSession.native, Self.setupPolicy + "\nCURRENT_CHECK=FIRST", nil, nil, { [state] pid in try state.spawned(firstSession, pid: pid) })
            driver = first
            let answer = try await first.run(question, false)
            guard first.exited(), answer?.trimmingCharacters(in: .whitespacesAndNewlines) == "FIRST" else { throw ClaudeSetupFailure.firstReply }
            try state.exited(firstSession, keep: false)
            try state.forget(connection: id)
            let secondSession = try state.session(connection: id, generation: UUID(), hash: "setup")
            recorded = secondSession
            stage = .resume
            let second = try await makeDriver(program, credential, id, secondSession.native, Self.setupPolicy + "\nCURRENT_CHECK=SECOND", nil, nil, { [state] pid in try state.spawned(secondSession, pid: pid) })
            driver = second
            guard first.hash == second.hash else { throw Refused.unavailable }
            let fresh = try await second.run(question, false)
            guard second.exited(), fresh?.trimmingCharacters(in: .whitespacesAndNewlines) == "SECOND" else { throw ClaudeSetupFailure.resume }
            try state.exited(secondSession, keep: false)
            let home = support.appendingPathComponent("brains/read-homes/" + id.uuidString)
            if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
            try state.setAccount(nil); try connections.disableAll()
            stage = .keychain
            try secrets.replace(credential)
            stage = .unavailable
            try state.setAccount(.init(program: program, hash: second.hash))
        } catch {
            driver?.stop()
            if driver?.exited() != false { try? state.exited(recorded, keep: false) }
            throw ClaudeSetupFailure.classify(error, stage: stage)
        }
    }

    private func send(scope: ClaudeReadConnections.Connection, requestID: UUID, text: String) async throws -> ConversationTurnStore.Record {
        if let previous = try receipts.record(conversationID: scope.id, requestID: requestID) {
            guard previous.text.unicodeScalars.elementsEqual(text.unicodeScalars) else { throw Refused.invalidRequest }; return previous
        }
        guard active[scope.id] == nil, preparing.isEmpty, !configuring else { throw Refused.busy }
        guard let account = try state.account(), let credential = try secrets.read() else { throw Refused.notConnected }
        _ = try currentFolder(scope)
        // A binder with file tools keeps one native session, whose static instructions stay in the prompt cache; it reads
        // the binder's current state itself. Without tools each turn is rebuilt from the durable app history and the scoped
        // source pack, so native cache can never freeze prior binder state.
        if (try? connections.allowsFileChanges(scope)) != true { try await fence(scope.id) }
        preparing.insert(scope.id); defer { preparing.remove(scope.id) }
        let session = try state.session(connection: scope.id, generation: scope.generation, hash: account.hash)
        if !session.resumed { try removeHome(scope.id) }
        guard case .reserved(let lease) = await admission.reserve(sessionID: session.native, kind: .conversation) else { throw Refused.busy }
        do {
            _ = try currentFolder(scope)
            let record = try receipts.accept(conversationID: scope.id, requestID: requestID, text: text)
            guard try receipts.claim(conversationID: scope.id, requestID: requestID) else { throw Refused.unavailable }
            let signal = StopSignal()
            let task = Task { await self.run(scope: scope, record: record, session: session, lease: lease,
                                             account: account, credential: credential, signal: signal) }
            active[scope.id] = Active(request: requestID, turn: record.turnID, signal: signal, task: task)
            return record
        } catch {
            _ = await admission.confirmedExit(lease)
            throw error
        }
    }

    private func run(scope: ClaudeReadConnections.Connection, record: ConversationTurnStore.Record,
                     session: ClaudeConversationState.Session, lease: AgentSessionAdmission.Lease,
                     account: ClaudeConversationState.Account, credential: String, signal: StopSignal) async {
        var keep = false, driver: Driver?
        var mayRelease = true
        let turnHistory = TurnHistory(support: support, binder: scope.id)
        do {
            let connections = self.connections, read = self.readContext, available = self.available, versions = turnHistory
            let writer = todoWriter, search = searchBinder
            let (context, reach, todos, revision) = try await Task.detached(priority: .userInitiated) {
                guard !signal.stopped else { throw Refused.stopped }
                let folder = try connections.currentFolder(scope)
                guard try available(folder) else { throw Refused.notConnected }
                // Only a binder that allowed file changes has a history, and its copies of the files. First the person's own
                // edits since the last record, so they are not taken for this turn's. Without that record the turn could not
                // be undone, so it runs with no tools rather than fail.
                var tools = (try? connections.allowsFileChanges(scope)) == true
                if tools { do { try versions.record(folder, cancelled: { signal.stopped }) } catch { tools = false } }
                guard !signal.stopped else { throw Refused.stopped }
                // Read before the source pack, so a to-do changed after the agent could have seen it counts as changed.
                let wholeBinder: @Sendable (String, Int) throws -> ClaudeBinderContext.Found = { query, limit in try search(folder, query, limit, { signal.stopped }) }
                let todos = ClaudeTodoTools(folder: folder, record: record, history: versions, writer: writer, search: tools ? wholeBinder : nil)
                // An agent with file tools finds what it needs itself; nothing of the binder is sent ahead of it.
                let context = tools ? ClaudeBinderContext(data: .obj([]), sources: []) : try read(folder, scope.documents, scope.intake, record.text, { signal.stopped })
                return (context, tools ? folder : nil, todos, tools ? ClaudeConversationPolicy.revision(of: folder) : nil)
            }.value
            guard !signal.stopped else { throw Refused.stopped }
            _ = try currentFolder(scope)
            let history = try receipts.history(conversationID: scope.id).filter { $0.requestID != record.requestID }
            let policy = try reach != nil ? ClaudeConversationPolicy.session(todos: todos != nil)
                : ClaudeConversationPolicy.make(context: context, history: session.resumed ? [] : history, tools: false, todos: todos != nil)
            let line = reach != nil ? ClaudeConversationPolicy.message(record.text, revision: revision, history: session.resumed ? [] : history.map { ($0.text, $0.reply) }) : record.text
            active[scope.id]?.indexing = false
            let made = try await makeDriver(account.program, credential, scope.id, session.native, policy, reach, todos?.appTools, { [state] pid in
                guard !signal.stopped else { throw Refused.stopped }
                try state.spawned(session, pid: pid)
            })
            driver = made; active[scope.id]?.driver = made
            guard !signal.stopped else { throw Refused.stopped }
            // prepare verifies Anthropic's signature for each launch; a normal Claude update may
            // change its binary hash without disconnecting the person's enabled account.
            _ = try currentFolder(scope)
            _ = await admission.started(lease); _ = await admission.beginTurn(lease)
            let result = try await made.run(line, session.resumed)
            if reach != nil { await recordTurn(record, scope: scope, history: turnHistory) }
            _ = try currentFolder(scope)
            if let result, !signal.stopped {
                _ = try receipts.finish(conversationID: scope.id, requestID: record.requestID, phase: .replied,
                                        reply: ClaudeBinderReply.normalize(result, sources: context.sources))
                keep = true
            } else {
                keep = session.resumed
                _ = try receipts.finish(conversationID: scope.id, requestID: record.requestID, phase: .interrupted)
            }
        } catch {
            if error as? ClaudeReadOnlyTurn.Failure == .exitUnconfirmed { mayRelease = false }
            // A session that has answered before stays usable after a turn that a limit or a Stop cut short. Any other failure,
            // or one in a session's first turn, starts the next turn fresh from the saved conversation.
            keep = session.resumed && (signal.stopped || [.usageLimit, .authentication, .deadline].contains(error as? ClaudeReadOnlyTurn.Failure))
            if !signal.stopped { noteFailure(of: record.requestID, error) }
            if (try? connections.allowsFileChanges(scope)) == true { await recordTurn(record, scope: scope, history: turnHistory) }
            _ = try? receipts.finish(conversationID: scope.id, requestID: record.requestID,
                                     phase: signal.stopped ? .interrupted : .failed)
        }
        if mayRelease && driver?.exited() != false {
            try? state.exited(session, keep: keep)
            _ = await admission.confirmedExit(lease)
            active.removeValue(forKey: scope.id)
        } // Otherwise the active entry and slot stay quarantined; no silent retry.
    }

    /// Keeps why a turn failed for the app to say, and logs it. A closed set of codes: no words of the turn reach the log.
    private func noteFailure(of request: UUID, _ error: Error) {
        let reason = Self.failureCode(error)
        if failureReasons.count >= 64 { failureReasons.removeAll() }
        failureReasons[request] = reason
        AtomicFile.appendLine("\(ISOTime.string(Date())) claude turn outcome=failed reason=\(reason)",
                              to: support.appendingPathComponent("runtime/jobs.log"))
    }

    static func failureCode(_ error: Error) -> String {
        if let failure = error as? ClaudeReadOnlyTurn.Failure {
            switch failure {
            case .busy: return "busy"
            case .startFailed: return "start_failed"
            case .protocolMismatch: return "protocol"
            case .authentication: return "authentication"
            case .usageLimit: return "usage_limit"
            case .engineFailed: return "engine"
            case .endedWithoutResult: return "ended_early"
            case .outputLimit: return "output_limit"
            case .deadline: return "deadline"
            case .exitUnconfirmed: return "exit_unconfirmed"
            case .replacementRequired: return "replacement_required"
            }
        }
        if error is ClaudeSetupFailure { return "setup" }
        if error as? Refused == .unavailable { return "binder_unavailable" }
        if error as? Refused == .tooLarge { return "too_large" }
        return "other"
    }

    /// What the turn changed, whether or not it finished. Runs before the turn's phase is reported, so the reply and its
    /// summary line arrive together. A second call for one turn finds nothing more and leaves the first entry.
    private func recordTurn(_ record: ConversationTurnStore.Record, scope: ClaudeReadConnections.Connection, history: TurnHistory) async {
        guard (try? history.entry(forTurn: record.turnID)) == nil else { return }
        let turn = record.turnID
        // A folder that cannot be found now is one more way to have no record, and the conversation says so.
        guard let folder = try? connections.currentFolder(scope) else { try? history.noteUnrecorded(turn: turn); return }
        await Task.detached(priority: .userInitiated) {
            do { try history.record(folder, turn: turn) } catch { try? history.noteUnrecorded(turn: turn) }
        }.value
    }

    private func fence(_ id: UUID) async throws {
        guard !preparing.contains(id) else { throw Refused.busy }
        if let current = active[id] {
            current.signal.stop(); current.driver?.stop(); await current.task.value
            guard current.driver?.exited() != false, active[id] == nil else { throw Refused.unavailable }
        }
        try state.forget(connection: id)
        try removeHome(id)
    }
    /// Directory names are generated by Sprava, never from a binder/model path.
    private func removeHome(_ id: UUID) throws {
        let home = support.appendingPathComponent("brains/read-homes/" + id.uuidString)
        if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
    }
    private func stopAll() async throws { for id in Array(active.keys) { try await fence(id) } }

    private func recover() async throws {
        guard !recovered else { return }
        // No awaits until all recorded workers are fenced. A reused pid is never signalled.
        for session in try state.allSessions() {
            if let pid = session.worker, let started = session.started,
               let actual = ProcessCheck.startTime(pid: pid), abs(actual.timeIntervalSince1970 - started) < 0.001 {
                killpg(pid, SIGKILL)
                for _ in 0..<100 where kill(pid, 0) == 0 { usleep(10_000) }
                guard kill(pid, 0) != 0, errno == ESRCH else { throw Refused.unavailable }
            }
            // Whatever an agent's commands left running when the runtime stopped.
            guard AgentContainment.sweep(session: session.native) else { throw Refused.unavailable }
            try receipts.recoverInterrupted(conversationID: session.connection)
            for record in try receipts.history(conversationID: session.connection) where record.phase == .accepted {
                _ = try receipts.finish(conversationID: session.connection, requestID: record.requestID, phase: .interrupted)
            }
            if session.worker != nil { try state.exited(session, keep: false) }
        }
        recovered = true
    }

    private func scopeJSON(_ scope: ClaudeReadConnections.Connection) -> JSONObject {
        .init([(key: "enabled", value: .bool(true)), (key: "binder_id", value: .str(scope.id.uuidString)),
               (key: "documents", value: .bool(scope.documents)), (key: "intake", value: .bool(scope.intake)),
               (key: "files", value: .bool((try? connections.allowsFileChanges(scope)) == true))])
    }
    private func recordJSON(_ r: ConversationTurnStore.Record) -> JSONValue {
        var fields: [(String, JSONValue)] = [("binder_id", .str(r.conversationID.uuidString)), ("request_id", .str(r.requestID.uuidString)),
              ("turn_id", .str(r.turnID.uuidString)), ("text", .str(r.text)), ("phase", .str(r.phase.rawValue)), ("reply", r.reply.map(JSONValue.str) ?? .null)]
        if r.phase == .failed, let reason = failureReasons[r.requestID] { fields.append(("reason", .str(reason))) }
        let history = TurnHistory(support: support, binder: r.conversationID)
        let entry = try? history.entry(forTurn: r.turnID), todos = try? history.todoChanges(forTurn: r.turnID), notes = try? history.notesChange(forTurn: r.turnID)
        if entry != nil || todos != nil || notes != nil {
            let summary = [entry?.summary, todos?.summary, notes == nil ? nil : "Updated the notes"].compactMap { $0 }.joined(separator: ". ")
            fields.append(("changes", .obj([("summary", .str(summary)), ("undone", .bool(entry?.undone ?? true && todos?.undone ?? true && notes?.undone ?? true)),
                                            ("undoable", .bool(todos != nil || notes != nil || entry?.unrecorded == false))])))
        }
        return .obj(fields)
    }
    private static let setupQuestion = "Read CURRENT_CHECK in the app's current policy and return only its exact value."
    private static let setupPolicy = "Sprava connection check only. No binder data or tools. On every turn the newest CURRENT_CHECK overrides any earlier value."

    private func currentFolder(_ scope: ClaudeReadConnections.Connection) throws -> URL {
        let folder = try connections.currentFolder(scope)
        guard try available(folder) else { throw Refused.notConnected }; return folder
    }

    func beginLifecycle(folder: URL) async throws -> UUID {
        try await recover()
        guard !configuring, preparing.isEmpty else { throw Refused.busy }
        configuring = true
        do {
            if let id = try connections.savedID(for: folder) {
                try await fence(id)
                if let scope = try connections.activeConnections().first(where: { $0.id == id }) { try connections.disable(scope) }
                // Its copies of the binder's files must not outlive a binder being removed or offloaded.
                try TurnHistory(support: support, binder: id).forget()
            }
            let ticket = UUID(); lifecycleTicket = ticket; return ticket
        } catch { configuring = false; throw error }
    }
    func finishLifecycle(_ ticket: UUID) {
        guard lifecycleTicket == ticket else { return }; lifecycleTicket = nil; configuring = false
    }

    /// Also fences a removal/offload queued through other installation controls before another
    /// request can use it. This reads only local availability metadata, never credentials or content.
    public func reconcileAvailability() async {
        guard !configuring, preparing.isEmpty else { return }
        do {
            try await recover()
            for scope in try connections.activeConnections() {
                if (try? currentFolder(scope)) == nil {
                    configuring = true
                    do { try await fence(scope.id); try connections.disable(scope) }
                    catch { configuring = false; return }
                    configuring = false
                }
            }
        } catch { return }
    }
}
