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
    /// Called when a request finds no runtime under its name; the app starts it there (decisions.md A19).
    static var whenNotRunning: (@MainActor () -> Void)?
    /// Run after every answer from the runtime, a refusal included.
    private var answered: [@MainActor () -> Void] = []

    /// Commands that only read. One that fails to reach the runtime is sent once more on a new connection: the first
    /// may have been made before the runtime was there, or kept from a runtime since restarted.
    static let reads: Set<String> = ["ping", "unfiled", "readings", "binder_settings", "proposals", "history",
                                     "list_clients", "backup_status"]

    init(answer: (@MainActor (String) async throws -> String)? = nil) {
        self.answer = answer
    }

    struct Failure: Error, CustomStringConvertible {
        enum Kind: Sendable { case refused, notRunning, timedOut }
        let message: String
        var kind = Kind.refused
        var description: String { message }

        /// What a page says when the runtime cannot be reached.
        static let notRunningLine = "Sprava's background part is not running. Sprava is starting it; Health, at the top of the sidebar, says if it cannot."

        /// The connection failed: nothing answers under the runtime's name. The system's own words ("Couldn't communicate
        /// with a helper application") and its code tell a person nothing they can act on; the code goes to the log.
        static func notRunning(_ error: Error) -> Failure {
            Failure(message: notRunningLine, kind: .notRunning)
        }
    }

    /// Clears the model's message once the runtime answers, when the message says the runtime is not running: the
    /// line was true when written, and a page must not keep saying it while the runtime runs.
    func clearsNotRunning<Model: AnyObject>(_ model: Model, _ message: ReferenceWritableKeyPath<Model, String?>) {
        answered.append { [weak model] in
            guard let model, model[keyPath: message]?.contains(Failure.notRunningLine) == true else { return }
            model[keyPath: message] = nil
        }
    }

    /// Whether the runtime is there, asked with the `ping` command.
    enum Presence: Sendable { case answers, notRunning, silent }

    /// `notRunning` when the connection fails, which it does at once when nothing is registered under the runtime's
    /// name; `silent` when no answer comes in time (launchd still starting it, or a long command ahead of the ping);
    /// `answers` for any reply, a refusal included.
    func presence(timeout: TimeInterval = 2) async -> Presence {
        do {
            _ = try await global("ping", timeout: timeout)
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
    func send(_ request: JSONObject, timeout: TimeInterval) async throws -> JSONObject {
        let text = JSONWriter.compact(.object(request))
        let read = Self.reads.contains(request["command"]?.stringValue ?? "")
        let reply: String
        do {
            do {
                reply = try await deliver(text, timeout: timeout)
            } catch let failure as Failure where failure.kind == .notRunning && read {
                reply = try await deliver(text, timeout: timeout)
            }
        } catch let failure as Failure where failure.kind == .notRunning {
            RuntimeClient.whenNotRunning?()
            throw failure
        }
        for run in answered { run() }
        guard case .object(let o) = try JSONParser.parse(reply).value else { throw Failure(message: "bad reply") }
        guard o["ok"] == .bool(true) else { throw Failure(message: o["error"]?.stringValue ?? "refused") }
        return o
    }

    private func deliver(_ text: String, timeout: TimeInterval) async throws -> String {
        if let answer { return try await answer(text) }
        let c = openConnection()
        do {
            return try await viaXPC(text, on: c, timeout: timeout)
        } catch let failure as Failure where failure.kind == .notRunning {
            // A failed connection is never used again; the next request makes a new one.
            drop(c)
            throw failure
        }
    }

    private func openConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: XPCNames.runtime, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: SpravaRuntimeXPC.self)
        let id = ObjectIdentifier(c)
        c.invalidationHandler = { [weak self] in Task { @MainActor in self?.forget(id) } }
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

    private func viaXPC(_ text: String, on c: NSXPCConnection, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
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
            proxy.handle(text) { answer in
                if once.claim() { continuation.resume(returning: answer) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
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
