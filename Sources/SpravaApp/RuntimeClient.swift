import Foundation
import os
import Services
import SpravaKit

/// Codes only (architecture 3.7): the connection's error code, for diagnosis, never shown on a page.
private let connectionLog = Logger(subsystem: "ca.orlenko.sprava", category: "runtime-client")

/// The app's side of the XPC connection. The app never writes a binder: every change goes to the runtime, the
/// single writer. Each request has a timeout (5 s for reads, 15 s for changes; architecture 2.1).
@MainActor
final class RuntimeClient {
    private var connection: NSXPCConnection?
    /// Answers in place of the runtime, for tests: no test reaches a runtime over XPC.
    private let answer: (@MainActor (String) async throws -> String)?
    /// The runtime's XPC name; tests name one that does not exist.
    private let serviceName: String
    private let onNotRunning: (@MainActor () -> Void)?
    /// Called when a request finds no runtime under its name; the app starts it there (decisions.md A19).
    static var whenNotRunning: (@MainActor () -> Void)?
    /// Run after every answer from the runtime, a refusal included.
    private var answered: [@MainActor () -> Void] = []

    /// Commands that only read when sent with no fields (`binder_settings` with fields saves). A read that fails to
    /// reach the runtime is sent once more on a new connection: the first may have been made before the runtime was
    /// there, or kept from a runtime since restarted.
    static let reads: Set<String> = ["ping", "unfiled", "readings", "binder_settings", "proposals", "history",
                                     "list_clients", "backup_status", "claude_status", "claude_binder", "chat_history", "imap_status"]

    static func isRead(_ request: JSONObject) -> Bool {
        guard let name = request["command"]?.stringValue, reads.contains(name) else { return false }
        return request.keys.allSatisfy { $0 == "command" || $0 == "binder" }
    }

    init(answer: (@MainActor (String) async throws -> String)? = nil, serviceName: String = XPCNames.runtime,
         onNotRunning: (@MainActor () -> Void)? = nil) {
        self.answer = answer
        self.serviceName = serviceName
        self.onNotRunning = onNotRunning
    }

    struct Failure: Error, CustomStringConvertible {
        enum Kind: Sendable { case refused, notRunning, timedOut }
        let message: String
        var kind = Kind.refused
        var description: String { message }

        /// What a page says when the runtime cannot be reached.
        static let notRunningLine = "Sprava's background part is not running. Sprava is starting it; Health, at the top of the sidebar, says if it cannot."
        /// What a page says when a change could not reach the runtime. The connection may have failed after the
        /// runtime took the change, so it says "may".
        static let changeNotRunningLine = "Sprava's background part was not running, so this may not have been saved. Sprava is starting it; reload to check, then try again."

        /// The connection failed: nothing answers under the runtime's name. The system's own words ("Couldn't communicate
        /// with a helper application") and its code tell a person nothing they can act on; the code goes to the log.
        static func notRunning(_ error: Error) -> Failure {
            Failure(message: notRunningLine, kind: .notRunning)
        }
    }

    /// Clears the page's message once the runtime answers, when a read left it because the runtime was not running
    /// (`RuntimePage.readFailed`): the line was true when written, and the page must not keep saying it while the
    /// runtime runs. A change's failure stays: the person must see that it was not saved.
    func clearsNotRunning(_ page: some RuntimePage) {
        answered.append { [weak page] in
            guard let page, page.readFoundNoRuntime else { return }
            page.message = nil
        }
    }

    /// Whether the runtime is there, asked with the `ping` command.
    enum Presence: Sendable { case answers, notRunning, silent }

    /// `notRunning` when the connection fails, which it does at once when nothing is registered under the runtime's
    /// name; `silent` when no answer comes in time (launchd still starting it, or a long command ahead of the ping);
    /// `answers` for any reply, a refusal included.
    func presence(timeout: TimeInterval = 2) async -> Presence {
        do {
            // Readiness/Health checks observe only; the caller decides whether to start the runtime.
            _ = try await send(JSONObject([("command", .string("ping"))]), timeout: timeout, startIfMissing: false)
            return .answers
        } catch let failure as Failure {
            switch failure.kind {
            case .notRunning: return .notRunning
            case .timedOut: return .silent
            case .refused: return .answers
            }
        } catch {
            return .answers
        }
    }

    /// Sends one request and returns the reply object. Throws when the runtime does not answer in time or
    /// answers `ok: false`. A read that does not reach the runtime is sent once more (`reads`); a change is not,
    /// so nothing is applied twice.
    func send(_ request: JSONObject, timeout: TimeInterval, startIfMissing: Bool = true) async throws -> JSONObject {
        let text = JSONWriter.compact(.object(request))
        let read = Self.isRead(request)
        let reply: String
        do {
            do {
                reply = try await deliver(text, timeout: timeout)
            } catch let failure as Failure where failure.kind == .notRunning && read {
                reply = try await deliver(text, timeout: timeout)
            }
        } catch let failure as Failure where failure.kind == .notRunning {
            if startIfMissing { (onNotRunning ?? RuntimeClient.whenNotRunning)?() }
            // A change's line stays true once the runtime runs, so the page keeps it until the next action.
            throw read ? failure : Failure(message: Failure.changeNotRunningLine, kind: .notRunning)
        }
        return try object(reply)
    }

    /// A file the app opened from a drop, handed to the runtime as an open descriptor (conversation.md 5.1). Never sent
    /// twice: a second send after a lost reply could copy the file twice.
    func importFile(binder: URL, name: String, file: FileHandle, timeout: TimeInterval = 120) async throws -> JSONObject {
        let text = JSONWriter.compact(.obj([("command", .str("intake_drop")), ("binder", .str(binder.standardizedFileURL.path)), ("name", .str(name))]))
        let reply: String
        if let answer { reply = try await answer(text) } else {
            let c = openConnection()
            do {
                reply = try await viaXPC(text, on: c, timeout: timeout) { proxy, done in proxy.importFile(text, file: file, reply: done) }
            } catch let failure as Failure where failure.kind == .notRunning {
                drop(c)
                (onNotRunning ?? RuntimeClient.whenNotRunning)?()
                throw Failure(message: Failure.changeNotRunningLine, kind: .notRunning)
            }
        }
        return try object(reply)
    }

    private func object(_ reply: String) throws -> JSONObject {
        for run in answered { run() }
        guard case .object(let o) = try JSONParser.parse(reply).value else { throw Failure(message: "bad reply") }
        guard o["ok"] == .bool(true) else { throw Failure(message: o["error"]?.stringValue ?? "refused") }
        return o
    }

    private func deliver(_ text: String, timeout: TimeInterval) async throws -> String {
        if let answer { return try await answer(text) }
        let c = openConnection()
        do {
            return try await viaXPC(text, on: c, timeout: timeout) { proxy, done in proxy.handle(text, reply: done) }
        } catch let failure as Failure where failure.kind == .notRunning {
            // A failed connection is never used again; the next request makes a new one.
            drop(c)
            throw failure
        }
    }

    private func openConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: serviceName, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: SpravaRuntimeXPC.self)
        let id = ObjectIdentifier(c)
        c.invalidationHandler = { @Sendable [weak self] in Task { @MainActor in self?.forget(id) } }
        c.resume()
        connection = c
        return c
    }

    private func drop(_ c: NSXPCConnection) {
        forget(ObjectIdentifier(c))
        c.invalidate()
    }

    /// Forgets the connection only if it is still the one kept: a late invalidation never drops a newer one.
    private func forget(_ id: ObjectIdentifier) {
        if let connection, ObjectIdentifier(connection) == id { self.connection = nil }
    }

    /// XPC calls its error and reply blocks on its own queue, so they are `@Sendable`: a block isolated to the main
    /// actor, as one written here would be, traps the app the moment the runtime cannot be reached.
    private func viaXPC(_ text: String, on c: NSXPCConnection, timeout: TimeInterval,
                        call: (SpravaRuntimeXPC, @escaping @Sendable (String) -> Void) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let proxy = c.remoteObjectProxyWithErrorHandler { @Sendable error in
                if once.claim() {
                    connectionLog.notice("runtime connection failed code=\((error as NSError).code, privacy: .public)")
                    continuation.resume(throwing: Failure.notRunning(error))
                }
            } as? SpravaRuntimeXPC
            guard let proxy else {
                if once.claim() {
                    connectionLog.notice("runtime connection failed code=no_proxy")
                    continuation.resume(throwing: Failure(message: Failure.notRunningLine, kind: .notRunning))
                }
                return
            }
            call(proxy) { @Sendable answer in
                if once.claim() { continuation.resume(returning: answer) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { @Sendable in
                if once.claim() {
                    continuation.resume(throwing: Failure(message: "Runtime not answering in time. The change may still be applied; reload to check before trying again.",
                                                          kind: .timedOut))
                }
            }
        }
    }

    func global(_ name: String, _ fields: [(String, JSONValue)] = [], timeout: TimeInterval = 15) async throws -> JSONObject {
        var r = JSONObject([(key: "command", value: .string(name))])
        for (k, v) in fields { r.set(k, v) }
        return try await send(r, timeout: timeout)
    }

    func command(_ name: String, binder: URL, _ fields: [(String, JSONValue)] = [], timeout: TimeInterval = 15) async throws -> JSONObject {
        var r = JSONObject([(key: "command", value: .string(name)), (key: "binder", value: .string(binder.standardizedFileURL.path))])
        for (k, v) in fields { r.set(k, v) }
        return try await send(r, timeout: timeout)
    }
}

/// A page that reads from the runtime and shows one message. Its `message` resets `readFoundNoRuntime` whenever it is
/// set (a `didSet`), so only the line a read left is ever cleared by `RuntimeClient.clearsNotRunning`.
@MainActor
protocol RuntimePage: AnyObject {
    var message: String? { get set }
    var readFoundNoRuntime: Bool { get set }
}

extension RuntimePage {
    /// Shows a read's failure; one that found the runtime not running is marked, so the next answer clears it. It never
    /// covers a change's failure for the same reason: that line says what may not have been saved, and stays.
    func readFailed(_ text: String, _ error: Error) {
        let noRuntime = (error as? RuntimeClient.Failure)?.kind == .notRunning
        if noRuntime, !readFoundNoRuntime, message?.contains(RuntimeClient.Failure.changeNotRunningLine) == true { return }
        message = text
        readFoundNoRuntime = noRuntime
    }
}

/// Resumes a continuation at most once across the reply, the error handler and the timeout.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
