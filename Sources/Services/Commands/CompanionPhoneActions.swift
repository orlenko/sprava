import Companion
import SpravaKit

/// Fixed app-facing errors; no relay body, credential or underlying error description reaches the person.
public enum CompanionPhoneActionError: Error, Sendable, Equatable {
    case invalidSetup, alreadyClaimed, resetRequired, unavailable, busy
    public var message: String {
        switch self {
        case .invalidSetup: "Check the relay address, setup code and web app address."
        case .alreadyClaimed: "This relay was claimed by another setup. Start a new relay instance to use it here."
        case .resetRequired: "Phone access needs an explicit reset before changing this setup."
        case .unavailable: "Phone access could not finish. Check its state before retrying."
        case .busy: "Another Phone action is running. Try again when it finishes."
        }
    }
}

/// Async configure/claim contracts for the Phone screen (§6). Runtime registers these on its Phone queue,
/// never on Commands' synchronous binder writer. Reset, pairing and device actions remain separate.
public enum CompanionPhoneActions {
    public typealias Handler = @Sendable (JSONObject) async throws -> JSONObject
    public static func handlers(session: CompanionOwnerSession) -> [String: Handler] {
        [
            "companion_configure": { request in
                guard request["command"] == .str("companion_configure"),
                      Set(request.entries.map(\.key)).isSubset(of: ["command", "relay_origin", "setup_code", "web_origin"]),
                      let origin = request["relay_origin"]?.stringValue, let code = request["setup_code"]?.stringValue,
                      request["web_origin"] == nil || request["web_origin"]?.stringValue != nil else {
                    throw CompanionPhoneActionError.invalidSetup
                }
                return try await perform {
                    try await session.configure(origin: origin, setupCode: code,
                                                webOrigin: request["web_origin"]?.stringValue)
                }
            },
            "companion_claim": { request in
                guard request["command"] == .str("companion_claim"),
                      Set(request.entries.map(\.key)).isSubset(of: ["command"]) else {
                    throw CompanionPhoneActionError.invalidSetup
                }
                return try await perform { try await session.recoverClaim() }
            },
        ]
    }
    private static func perform(_ action: () async throws -> CompanionOwnerRuntimeStatus) async throws -> JSONObject {
        do {
            let status = try await action()
            let word: String
            switch status {
            case .notConfigured: word = "not-configured"
            case .claim(let state): word = state.rawValue
            }
            return JSONObject([(key: "state", value: .string(word))])
        } catch is CancellationError {
            throw CancellationError()
        } catch CompanionOwnerConnectionError.busy {
            throw CompanionPhoneActionError.busy
        } catch let error as CompanionOwnerSetupError {
            switch error {
            case .invalid: throw CompanionPhoneActionError.invalidSetup
            case .alreadyClaimed: throw CompanionPhoneActionError.alreadyClaimed
            case .reconfigurationRequired: throw CompanionPhoneActionError.resetRequired
            case .relayUnavailable: throw CompanionPhoneActionError.unavailable
            }
        } catch {
            throw CompanionPhoneActionError.unavailable
        }
    }
}
