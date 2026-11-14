import Companion
import Foundation
import SpravaKit

/// Remove a phone (companion-v0 §4.4) and drive what is left on the relay. Removal on this Mac is immediate: the
/// phone is revoked and its key deleted at once. The relay deletion, the new keys for the remaining phones and the
/// discard of old keys follow in bounded steps, here and from the person's Retry, until a background job runs them.
enum CompanionRemovalActions {
    typealias Handler = CompanionPhoneActions.Handler
    /// Network calls per action, each at most 30 seconds (the app waits 100).
    static let callsPerAction = 3

    static func handlers(session: CompanionOwnerSession) -> [String: Handler] {
        [
            "companion_device_remove": { request in
                let device = try CompanionPairingActions.fields(request, "companion_device_remove", ["device_id"])[0]
                return try await CompanionPairingActions.configured(session) { profile in
                    // Idempotent: removing a removed phone returns its receipt and continues its relay work (Retry).
                    _ = try await CompanionDeviceRemoval(profile: profile, locks: session.deviceDecisionLocks).record(deviceID: device)
                    await advance(profile, step: session.rotation(profile))
                    var reply = JSONObject([("state", .str("removed"))])
                    for (key, value) in try relayWork(profile) { reply.set(key, value) }
                    return reply
                }
            },
            "companion_relay_retry": { request in
                _ = try CompanionPairingActions.fields(request, "companion_relay_retry", [])
                return try await CompanionPairingActions.configured(session) { profile in
                    // The person's retry after a relay fault: a new rotation replaces the refused keys objects.
                    if try profile.rotationFault() { try profile.requestRotation() }
                    await advance(profile, step: session.rotation(profile))
                    var reply = JSONObject([("state", .str("checked"))])
                    for (key, value) in try relayWork(profile) { reply.set(key, value) }
                    return reply
                }
            },
        ]
    }

    /// Local key cleanup, then at most `limit` relay calls (`callsPerAction` for a Phone action; the companion job
    /// allows more). Failures stay pending and are reported by `relayWork`; a refused keys object stops the steps
    /// (a fault, never retried by itself).
    static func advance(_ profile: CompanionProfile, limit: Int = callsPerAction,
                        step: @Sendable () async throws -> CompanionRotationProgress) async {
        for removal in (try? profile.pendingDeviceRemovals().removals) ?? [] where removal.keyCleanupPending {
            _ = try? profile.finishRemovedDeviceKeyCleanup(deviceID: removal.deviceID)
        }
        var calls = 0
        for _ in 0..<(limit + 3) where calls < limit {
            guard !Task.isCancelled, let progress = try? await step() else { return }
            switch progress {
            case .rotated, .discarded: continue
            case .deleted, .uploaded: calls += 1
            case .idle, .waiting, .refused: return
            }
        }
    }

    /// Keyless: removed phones the relay has not confirmed, whether relay work remains, and whether the relay
    /// refused a keys object. For Settings › Phone only (labels are private).
    static func relayWork(_ profile: CompanionProfile) throws -> [(String, JSONValue)] {
        let removed = try profile.removalsAwaitingRelay()
        let blocked = try profile.rotationBlocksPublication(), fault = try profile.rotationFault()
        return [
            ("removed", .array(removed.map { .obj([("device_id", .string($0.deviceID)), ("label", .string($0.label))]) })),
            ("relay_pending", .bool(!removed.isEmpty || blocked)),
            ("relay_fault", .bool(fault)),
        ]
    }
}
