import Foundation
import Services
import SpravaKit

/// The app's side of the XPC connection. The app never writes a binder: every change goes to the runtime, the
/// single writer. Each request has a timeout (5 s for reads, 15 s for changes; architecture 2.1).
@MainActor
final class RuntimeClient {
    private var connection: NSXPCConnection?
    /// Answers in place of the runtime, for tests: no test reaches a runtime over XPC.
    private let answer: (@MainActor (String) async throws -> String)?
    /// Called when a request finds no runtime under its name; the app starts it there (decisions.md A16).
    static var whenNotRunning: (@MainActor () -> Void)?

    init(answer: (@MainActor (String) async throws -> String)? = nil) {
        self.answer = answer
    }

    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> SpravaRuntimeXPC? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: XPCNames.runtime, options: [])
            c.remoteObjectInterface = NSXPCInterface(with: SpravaRuntimeXPC.self)
            c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? SpravaRuntimeXPC
    }

    struct Failure: Error, CustomStringConvertible {
        enum Kind: Sendable { case refused, notRunning, timedOut }
        let message: String
        var kind = Kind.refused
        var description: String { message }

        /// The connection failed: nothing answers under the runtime's name. The system's own words ("Couldn't communicate
        /// with a helper application") tell a person nothing they can act on, so only the error's code is kept, for diagnosis.
        static func notRunning(_ error: Error) -> Failure {
            Failure(message: "Sprava's background part is not running. Sprava is starting it; Health, at the top of the sidebar, says if it cannot. (error \((error as NSError).code))",
                    kind: .notRunning)
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
    /// answers `ok: false`.
    func send(_ request: JSONObject, timeout: TimeInterval) async throws -> JSONObject {
        let text = JSONWriter.compact(.object(request))
        let reply: String = if let answer { try await answer(text) } else { try await viaXPC(text, timeout: timeout) }
        guard case .object(let o) = try JSONParser.parse(reply).value else { throw Failure(message: "bad reply") }
        guard o["ok"] == .bool(true) else { throw Failure(message: o["error"]?.stringValue ?? "refused") }
        return o
    }

    private func viaXPC(_ text: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let proxy = self.proxy { error in
                if once.claim() {
                    continuation.resume(throwing: Failure.notRunning(error))
                    Task { @MainActor in RuntimeClient.whenNotRunning?() }
                }
            }
            guard let proxy else {
                if once.claim() {
                    continuation.resume(throwing: Failure(message: "Sprava's background part is not running. Sprava is starting it; Health, at the top of the sidebar, says if it cannot.",
                                                          kind: .notRunning))
                    RuntimeClient.whenNotRunning?()
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
