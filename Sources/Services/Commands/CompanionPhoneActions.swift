import Companion
import SpravaKit

/// Fixed app-facing errors; no relay body, credential or underlying error description reaches the person.
public enum CompanionPhoneActionError: Error, Sendable, Equatable {
    case invalidSetup, alreadyClaimed, resetRequired, unavailable, busy
    case invalidRequest, notClaimed, ownerRefused, webOriginMissing, pairingExpired, pairingInvalid
    case notSetUp, notShowable, tooManyShown
    public var message: String {
        switch self {
        case .notSetUp: "Connect this Mac to a relay in Settings › Phone first."
        case .notShowable: "Only an adopted binder on the Shelf that this Mac manages can be shown on the phone."
        case .tooManyShown: "At most 100 binders can be shown on the phone. Turn one off first."
        case .invalidSetup: "Check the relay address, setup code and web app address."
        case .alreadyClaimed: "This relay was claimed by another setup. Start a new relay instance to use it here."
        case .resetRequired: "Phone access needs an explicit reset before changing this setup."
        case .unavailable: "Phone access could not finish. Check its state before retrying."
        case .busy: "Another Phone action is running. Try again when it finishes."
        case .invalidRequest: "Phone request is invalid."
        case .notClaimed: "Connect this Mac to a relay and claim it before pairing a phone."
        case .ownerRefused: "The relay did not accept this Mac. Claim the relay again, then retry."
        case .webOriginMissing: "Add the web app address to the relay setup, then pair again."
        case .pairingExpired: "This pairing expired. Start pairing again."
        case .pairingInvalid: "This pairing could not be checked. Start pairing again."
        }
    }
}

/// Async Phone screen contracts (§6). Runtime registers these on its Phone queue, never on Commands'
/// synchronous binder writer. Device removal and reset are not handled yet.
public enum CompanionPhoneActions {
    public typealias Handler = @Sendable (JSONObject) async throws -> JSONObject
    public static func handlers(session: CompanionOwnerSession) -> [String: Handler] {
        setup(session: session).merging(CompanionPairingActions.handlers(session: session)) { first, _ in first }
    }
    private static func setup(session: CompanionOwnerSession) -> [String: Handler] {
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
