import Companion
import Foundation

/// The part of the owner's publisher the drain uses for each phone's outcomes; tests stand in for the relay through it.
protocol CompanionOutcomesTarget: Sendable {
    func uploadOutcomes(deviceID: String, generatedAt: String) async throws -> CompanionPublicationProgress
}
extension CompanionOwnerPublication: CompanionOutcomesTarget {}

/// companion-v0 §9.2 for the runtime: one bounded drain of the phones' requests after each publishing pass, then each
/// phone's outcomes. One instance per runtime: its device turn keeps, in memory, the requests it confirmed lost, so a
/// later drain gets past them (§9.3 check 4); it is made again only for another relay.
actor CompanionDraining {
    typealias MakeTurn = @Sendable (CompanionProfile, CompanionDeviceDecisionLocks) throws -> CompanionOwnerDeviceTurn
    private let support: URL
    private let deviceID: String
    private let makeTurn: MakeTurn
    private let drain = CompanionOwnerDrain()
    private var turn: (relay: [String], turn: CompanionOwnerDeviceTurn)?

    init(support: URL, deviceID: String,
         makeTurn: @escaping MakeTurn = { try CompanionOwnerDeviceTurn(profile: $0, locks: $1) }) {
        self.support = support; self.deviceID = deviceID; self.makeTurn = makeTurn
    }

    func run(profile: CompanionProfile, locks: CompanionDeviceDecisionLocks, outcomes: any CompanionOutcomesTarget,
             timeZone: TimeZone = .current, clock: @escaping @Sendable () -> Date = { Date() }) async throws -> CompanionDrainReport {
        let relay = [profile.relayIdentity.origin, profile.relayIdentity.instance]
        if turn?.relay != relay { turn = (relay, try makeTurn(profile, locks)) }
        guard let deviceTurn = turn?.turn else { throw CompanionDecisionError.unavailable }
        let adapter = CompanionBinderDecisions(profile: profile, support: support, deviceID: deviceID, timeZone: timeZone, clock: clock)
        let now: @Sendable () -> String = { CompanionPublishing.time(clock()) }
        return try await drain.drain(activeDevices: try Self.activeDevices(profile, now: now()), now: now,
            turn: { device, allowance in try await deviceTurn.run(deviceID: device, allowance: allowance, now: now, adapter: adapter) },
            publishOutcomes: { device in
                // §9.9: under the device's decision lock, so a removal either retires the work or finds it reserved.
                do { _ = try await locks.withLock(deviceID: device) { try await outcomes.uploadOutcomes(deviceID: device, generatedAt: now()) } }
                catch CompanionOwnerConnectionError.busy { /* a decision or a removal holds it; the next drain publishes */ }
            })
    }

    /// Every phone active in this Mac's records (at most twenty), never the relay's list.
    static func activeDevices(_ profile: CompanionProfile, now: String) throws -> [String] {
        var devices: [String] = [], after: String?
        repeat {
            let page = try profile.pairedDevices(now: now, after: after)
            devices += page.devices.map(\.deviceID)
            after = page.next
        } while after != nil && devices.count < 1000
        return devices
    }
}
