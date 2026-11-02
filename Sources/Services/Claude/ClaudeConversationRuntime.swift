import BinderStore
import Backup
import Shelf
import Brains
import Darwin
import Foundation
import Retrieval
import SpravaKit

/// One app-authenticated, explicitly consented read/draft conversation per physical binder. Models
/// receive no tools or operation capability. Suggested tasks are data for a separate app confirmation.
public actor ClaudeConversationRuntime {
    public enum Refused: Error, Sendable { case notConnected, busy, unavailable, invalidRequest, stopped }
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
    typealias MakeDriver = @Sendable (URL, String, UUID, UUID, String, @escaping @Sendable (Int32) throws -> Void) async throws -> Driver
    typealias ReadContext = @Sendable (URL, Bool, Bool, String, @escaping @Sendable () -> Bool) throws -> ClaudeBinderContext
    private let support: URL
    private let connections: ClaudeReadConnections
    private var exports = ConversationExport()
    private let receipts: ConversationTurnStore
    private let state: ClaudeConversationState
    private let secrets: Secrets
    private let makeDriver: MakeDriver
    private let readContext: ReadContext
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

    init(support: URL, secrets: Secrets, makeDriver: @escaping MakeDriver, context: @escaping ReadContext, available: @escaping @Sendable (URL) throws -> Bool = { _ in true }) throws {
        self.support = support; self.available = available; self.secrets = secrets; self.makeDriver = makeDriver; readContext = context
        connections = try ClaudeReadConnections(at: support.appendingPathComponent("brains/read-scopes.sqlite"))
        receipts = try ConversationTurnStore(at: support.appendingPathComponent("binder-store/conversation.sqlite"))
        state = try ClaudeConversationState(at: support.appendingPathComponent("runtime/claude.sqlite"))
        admission = try AgentSessionAdmission(conversationLimit: 1, taskLimit: 1)
    }

    /// Production registration is explicit in the runtime. Initializing this owner opens only Sprava
    /// state; it does not read Keychain, launch a model, discover binders or enable a backend by itself.
    public static func production(support: URL) throws -> ClaudeConversationRuntime {
        try Self(support: support, secrets: ClaudeSubscriptionSecrets.keychain,
                 makeDriver: { program, credential, connection, session, policy, onSpawn in
            try await ClaudeNativeConversation.driver(program: program, support: support, credential: credential,
                                                      connection: connection, session: session, policy: policy, onSpawn: onSpawn)
        }, context: { folder, documents, intake, query, cancelled in
            try ClaudeBinderContext.build(folder: folder, support: support, documents: documents, intake: intake,
                                          query: query, reader: HelperDocumentReader(binder: folder, reader: .located()), cancelled: cancelled)
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

    public static let commands: Set<String> = ["claude_status", "claude_configure", "claude_disconnect", "claude_binder", "claude_enable", "claude_disable", "chat_send", "chat_poll", "chat_history", "chat_export", "chat_stop", "chat_clear"]

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
            let scope = try connections.enable(folder: folder, documents: request["documents"] == .bool(true), intake: request["intake"] == .bool(true))
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
            let first = try await makeDriver(program, credential, id, firstSession.native, Self.setupPolicy + "\nCURRENT_CHECK=FIRST", { [state] pid in try state.spawned(firstSession, pid: pid) })
            driver = first
            let answer = try await first.run(question, false)
            guard first.exited(), answer?.trimmingCharacters(in: .whitespacesAndNewlines) == "FIRST" else { throw ClaudeSetupFailure.firstReply }
            try state.exited(firstSession, succeeded: false)
            try state.forget(connection: id)
            let secondSession = try state.session(connection: id, generation: UUID(), hash: "setup")
            recorded = secondSession
            stage = .resume
            let second = try await makeDriver(program, credential, id, secondSession.native, Self.setupPolicy + "\nCURRENT_CHECK=SECOND", { [state] pid in try state.spawned(secondSession, pid: pid) })
            driver = second
            guard first.hash == second.hash else { throw Refused.unavailable }
            let fresh = try await second.run(question, false)
            guard second.exited(), fresh?.trimmingCharacters(in: .whitespacesAndNewlines) == "SECOND" else { throw ClaudeSetupFailure.resume }
            try state.exited(secondSession, succeeded: false)
            let home = support.appendingPathComponent("brains/read-homes/" + id.uuidString)
            if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
            try state.setAccount(nil); try connections.disableAll()
            stage = .keychain
            try secrets.replace(credential)
            stage = .unavailable
            try state.setAccount(.init(program: program, hash: second.hash))
        } catch {
            driver?.stop()
            if driver?.exited() != false { try? state.exited(recorded, succeeded: false) }
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
        // Native resume retains the old appended system prompt. Rebuild each turn from the durable app
        // history and current scoped source pack, so native cache can never freeze prior binder state.
        try await fence(scope.id)
        preparing.insert(scope.id); defer { preparing.remove(scope.id) }
        let session = try state.session(connection: scope.id, generation: scope.generation, hash: account.hash)
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
        var succeeded = false, driver: Driver?
        var mayRelease = true
        do {
            let connections = self.connections, read = self.readContext, available = self.available
            let context = try await Task.detached(priority: .userInitiated) {
                guard !signal.stopped else { throw Refused.stopped }
                let folder = try connections.currentFolder(scope)
                guard try available(folder) else { throw Refused.notConnected }
                return try read(folder, scope.documents, scope.intake, record.text, { signal.stopped })
            }.value
            guard !signal.stopped else { throw Refused.stopped }
            _ = try currentFolder(scope)
            let history = try receipts.history(conversationID: scope.id).filter { $0.requestID != record.requestID }
            let policy = try ClaudeConversationPolicy.make(context: context, history: session.resumed ? [] : history)
            active[scope.id]?.indexing = false
            let made = try await makeDriver(account.program, credential, scope.id, session.native, policy, { [state] pid in
                guard !signal.stopped else { throw Refused.stopped }
                try state.spawned(session, pid: pid)
            })
            driver = made; active[scope.id]?.driver = made
            guard !signal.stopped else { throw Refused.stopped }
            // prepare verifies Anthropic's signature for each launch; a normal Claude update may
            // change its binary hash without disconnecting the person's enabled account.
            _ = try currentFolder(scope)
            _ = await admission.started(lease); _ = await admission.beginTurn(lease)
            let result = try await made.run(record.text, false)
            _ = try currentFolder(scope)
            if let result, !signal.stopped {
                _ = try receipts.finish(conversationID: scope.id, requestID: record.requestID, phase: .replied,
                                        reply: ClaudeBinderReply.normalize(result, sources: context.sources))
                succeeded = true
            } else { _ = try receipts.finish(conversationID: scope.id, requestID: record.requestID, phase: .interrupted) }
        } catch {
            if error as? ClaudeReadOnlyTurn.Failure == .exitUnconfirmed { mayRelease = false }
            _ = try? receipts.finish(conversationID: scope.id, requestID: record.requestID,
                                     phase: signal.stopped ? .interrupted : .failed)
        }
        if mayRelease && driver?.exited() != false {
            try? state.exited(session, succeeded: succeeded)
            _ = await admission.confirmedExit(lease)
            active.removeValue(forKey: scope.id)
        } // Otherwise the active entry and slot stay quarantined; no silent retry.
    }

    private func fence(_ id: UUID) async throws {
        guard !preparing.contains(id) else { throw Refused.busy }
        if let current = active[id] {
            current.signal.stop(); current.driver?.stop(); await current.task.value
            guard current.driver?.exited() != false, active[id] == nil else { throw Refused.unavailable }
        }
        try state.forget(connection: id)
        // Directory names are generated by Sprava, never from a binder/model path.
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
            try receipts.recoverInterrupted(conversationID: session.connection)
            for record in try receipts.history(conversationID: session.connection) where record.phase == .accepted {
                _ = try receipts.finish(conversationID: session.connection, requestID: record.requestID, phase: .interrupted)
            }
            if session.worker != nil { try state.exited(session, succeeded: false) }
        }
        recovered = true
    }

    private func scopeJSON(_ scope: ClaudeReadConnections.Connection) -> JSONObject {
        .init([(key: "enabled", value: .bool(true)), (key: "binder_id", value: .str(scope.id.uuidString)),
               (key: "documents", value: .bool(scope.documents)), (key: "intake", value: .bool(scope.intake))])
    }
    private func recordJSON(_ r: ConversationTurnStore.Record) -> JSONValue {
        .obj([("binder_id", .str(r.conversationID.uuidString)), ("request_id", .str(r.requestID.uuidString)),
              ("turn_id", .str(r.turnID.uuidString)), ("text", .str(r.text)), ("phase", .str(r.phase.rawValue)), ("reply", r.reply.map(JSONValue.str) ?? .null)])
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
