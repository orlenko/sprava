import Foundation
import SpravaKit

/// Phone actions await Companion's bounded, cancellation-aware transports (§6) outside the binder writer.
/// One action is admitted at a time; another gets a visible busy answer rather than an unbounded queue.
/// Runtime keeps the returned task so a disconnected caller can cancel it. Handlers own all domain work.
public final class CompanionRequestQueue: @unchecked Sendable {
    public typealias Handler = @Sendable (JSONObject) async throws -> JSONObject
    public typealias Reply = @Sendable (_ answer: String, _ command: String, _ ms: Int) -> Void
    public static let actionNames: Set<String> = [
        "companion_configure", "companion_claim", "companion_pairing_start", "companion_pairing_poll",
        "companion_pairing_confirm", "companion_devices", "companion_device_remove", "companion_reset",
    ]
    private let handlers: [String: Handler]
    private let watch: WatchBox?
    private let lock = NSLock()
    private var running = false

    /// Only the reserved Phone action names may be registered; binder commands cannot enter this queue.
    public init(handlers: [String: Handler], watch: WatchBox?) throws {
        guard Set(handlers.keys).isSubset(of: Self.actionNames) else { throw InvalidRegistration() }
        self.handlers = handlers; self.watch = watch
    }
    public struct InvalidRegistration: Error, Sendable { public init() {} }
    public func handles(_ command: String) -> Bool { handlers[command] != nil }

    /// No network or credential work is performed until a bounded, unambiguous request has been admitted.
    /// Error descriptions can contain setup codes or relay bodies; replies use fixed sentences only.
    @discardableResult
    public func submit(_ request: String, reply: @escaping Reply) -> Task<Void, Never>? {
        let parsed = request.utf8.count <= 64 * 1024 ? try? JSONParser.parse(request) : nil
        guard let parsed, parsed.safety.isSafe, case .object(let object) = parsed.value,
              let command = object["command"]?.stringValue, let handler = handlers[command] else {
            reply(Self.failure("Phone request is invalid."), "?", 0)
            return nil
        }
        guard reserve() else {
            reply(Self.failure("Another Phone action is running. Try again when it finishes."), command, 0)
            return nil
        }
        let started = ContinuousClock.now
        watch?.started("app_companion_request")
        return Task {
            let answer: String
            do {
                try Task.checkCancellation()
                let result = try await handler(object)
                try Task.checkCancellation()
                // A handler supplies data, never a replacement for the command envelope.
                var envelope = JSONObject([(key: "ok", value: .bool(true))])
                for entry in result.entries where entry.key != "ok" && entry.key != "error" {
                    envelope.set(entry.key, entry.value)
                }
                answer = JSONWriter.compact(.object(envelope))
            } catch is CancellationError {
                answer = Self.failure("Phone action was cancelled. Check its state before retrying.")
            } catch let error as CompanionPhoneActionError {
                answer = Self.failure(error.message)
            } catch {
                answer = Self.failure("Phone action could not finish. Check its state before retrying.")
            }
            watch?.finished("app_companion_request")
            release()
            let elapsed = started.duration(to: ContinuousClock.now).components
            reply(answer, command, Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000))
        }
    }
    private func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return false }; running = true; return true
    }
    private func release() { lock.lock(); running = false; lock.unlock() }
    private static func failure(_ message: String) -> String {
        JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .string(message))]))
    }
}
