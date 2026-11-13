import Companion
import Foundation
import SpravaKit

/// One opened profile's pairing steps (companion-v0 §5.2). Production wraps Companion's flow and delivery and
/// defers refused-token recovery to a separate Claim, so one Phone action stays one bounded set of calls.
struct CompanionPairingSteps: Sendable {
    var start: @Sendable () async throws -> CompanionPairingStart
    var poll: @Sendable (String) async throws -> CompanionPairingPoll
    var approval: @Sendable (String) async throws -> CompanionPairingApproval?
    var confirm: @Sendable (CompanionPairingApproval) async throws -> Void
    var deliver: @Sendable (String) async throws -> CompanionPairingDeliveryProgress

    static let relay: @Sendable (CompanionProfile) throws -> CompanionPairingSteps = { profile in
        let flow = try CompanionOwnerPairingFlow(profile: profile, recoverRefusals: false)
        let delivery = try CompanionOwnerPairingDelivery(profile: profile, recoverRefusals: false)
        return CompanionPairingSteps(start: { try await flow.start() }, poll: { try await flow.poll(deviceID: $0) },
                                     approval: { try await flow.approval(deviceID: $0) },
                                     confirm: { _ = try await flow.confirm($0) },
                                     deliver: { try await delivery.step(deviceID: $0) })
    }
}

/// Pairing and device-list contracts for Settings › Phone. Replies carry state words, the QR link, the
/// device's label and the six-digit code for the screen only; the runtime logs none of them.
enum CompanionPairingActions {
    typealias Handler = CompanionPhoneActions.Handler
    static func handlers(session: CompanionOwnerSession) -> [String: Handler] {
        [
            "companion_pairing_start": { request in
                _ = try fields(request, "companion_pairing_start", [])
                return try await configured(session) { profile in
                    // Checked before reserving a device, so a missing address costs no relay call.
                    guard let setup = try profile.ownerConfiguration() else { throw CompanionPhoneActionError.notClaimed }
                    guard let web = setup.webOrigin else { throw CompanionPhoneActionError.webOriginMissing }
                    let relay = try CompanionRelayIdentity(origin: setup.origin, instance: setup.instance)
                    let start = try await session.pairing(profile).start()
                    let link = try CompanionPairingLink.make(webOrigin: web, relay: relay, start: start)
                    return JSONObject([("state", .str("waiting")), ("device_id", .string(start.deviceID)),
                                       ("link", .string(link)), ("expires_at", .string(start.deadline))])
                }
            },
            "companion_pairing_poll": { request in
                let device = try fields(request, "companion_pairing_poll", ["device_id"])[0]
                return try await configured(session) { profile in
                    let steps = try session.pairing(profile)
                    if try profile.pairingDelivery(deviceID: device) != nil {
                        switch try await steps.deliver(device) {
                        case .waiting(let retryAt):
                            return JSONObject([("state", .str("delivering")), ("retry_at", .string(retryAt))])
                        case .acknowledged: return JSONObject([("state", .str("paired"))])
                        case .notConfirmed: return JSONObject([("state", .str("not-confirmed"))])
                        }
                    }
                    // A code already shown is restored without another relay call (§5.2 step 3).
                    if let approval = try await steps.approval(device) { return confirmation(approval) }
                    switch try await steps.poll(device) {
                    case .waiting(let retryAt): return JSONObject([("state", .str("waiting")), ("retry_at", .string(retryAt))])
                    case .confirmation(let approval): return confirmation(approval)
                    }
                }
            },
            "companion_pairing_confirm": { request in
                let values = try fields(request, "companion_pairing_confirm", ["device_id", "confirmation"])
                return try await configured(session) { profile in
                    let steps = try session.pairing(profile)
                    // The person approved the code they saw; any other recorded transcript is refused.
                    guard let approval = try await steps.approval(values[0]), approval.confirmation == values[1] else {
                        throw CompanionPhoneActionError.pairingInvalid
                    }
                    try await steps.confirm(approval)
                    return JSONObject([("state", .str("delivering"))])
                }
            },
            "companion_devices": { request in
                guard request["command"] == .str("companion_devices"),
                      Set(request.entries.map(\.key)).isSubset(of: ["command", "after"]),
                      request["after"] == nil || request["after"]?.stringValue != nil else {
                    throw CompanionPhoneActionError.invalidRequest
                }
                let page: CompanionPairedDevicePage?
                do { page = try await session.pairedDevices(now: Date().ISO8601Format(), after: request["after"]?.stringValue) }
                catch { throw CompanionPhoneActionError.unavailable }
                guard let page else { return JSONObject([("devices", .array([]))]) }
                var reply = JSONObject([("devices", .array(page.devices.map { device in
                    .obj([("device_id", .string(device.deviceID)), ("label", .string(device.label)),
                          ("paired_at", .string(device.pairedAt)), ("confirmation", .string(device.confirmation.rawValue))])
                }))])
                if let next = page.next { reply.set("next", .string(next)) }
                return reply
            },
        ]
    }

    private static func confirmation(_ approval: CompanionPairingApproval) -> JSONObject {
        JSONObject([("state", .str("confirm")), ("label", .string(approval.label)),
                    ("confirmation", .string(approval.confirmation))])
    }
    /// Exactly the named string fields, so a binder path or extra field never reaches the relay work.
    private static func fields(_ request: JSONObject, _ command: String, _ names: [String]) throws -> [String] {
        guard request["command"] == .str(command),
              Set(request.entries.map(\.key)) == Set(["command"] + names) else { throw CompanionPhoneActionError.invalidRequest }
        return try names.map { name in
            guard let value = request[name]?.stringValue, !value.isEmpty, value.utf8.count <= 64 else {
                throw CompanionPhoneActionError.invalidRequest
            }
            return value
        }
    }
    private static func configured(_ session: CompanionOwnerSession,
                                   _ action: @escaping @Sendable (CompanionProfile) async throws -> JSONObject) async throws -> JSONObject {
        do {
            guard let reply = try await session.withConfiguredProfile(action) else { throw CompanionPhoneActionError.notClaimed }
            return reply
        } catch let error as CompanionPhoneActionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch CompanionOwnerConnectionError.busy {
            throw CompanionPhoneActionError.busy
        } catch CompanionPairingFlowError.busy {
            throw CompanionPhoneActionError.busy
        } catch CompanionPairingFlowError.ownerUnavailable {
            throw CompanionPhoneActionError.notClaimed
        } catch CompanionPairingFlowError.relayRejected(401) {
            throw CompanionPhoneActionError.ownerRefused
        } catch CompanionOwnerPairingError.expired {
            throw CompanionPhoneActionError.pairingExpired
        } catch CompanionOwnerPairingError.invalid {
            throw CompanionPhoneActionError.pairingInvalid
        } catch is CompanionPairingDeliveryError {
            throw CompanionPhoneActionError.pairingInvalid
        } catch {
            throw CompanionPhoneActionError.unavailable
        }
    }
}
