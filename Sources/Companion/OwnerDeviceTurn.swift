import Foundation

/// Higher binder adapters use this only for a busy binder or one needing attention (§9.2).
/// Disk, credential, transport and cancellation failures remain job failures.
public enum CompanionDeviceDecisionFailure: Error, Sendable { case binderUnavailable }

/// companion-v0 §§9.2–9.6: recover, collect, decide, commit and delete under one shared device lock.
/// Keep one instance per profile so the collector retains confirmed-lost knowledge across drains.
/// Binder/effect access stays in the injected adapter; clocks come from the Mac, never a request.
public struct CompanionOwnerDeviceTurn: Sendable {
    private let profile: CompanionProfile
    private let locks: CompanionDeviceDecisionLocks
    private let collector: CompanionOwnerRequestCollection
    private let transport: any RequestCollectionTransport
    public init(profile: CompanionProfile, locks: CompanionDeviceDecisionLocks) throws {
        guard let owner = try CompanionOwnerVault(backend: profile.secrets).load(profile.relay) else {
            throw CompanionCredentialError.unavailable
        }
        self.init(profile: profile, locks: locks,
                  transport: try CompanionOwnerRelay(relay: profile.relay, token: owner.ownerToken))
    }
    init(profile: CompanionProfile, locks: CompanionDeviceDecisionLocks, transport: any RequestCollectionTransport) {
        self.profile = profile; self.locks = locks; self.transport = transport
        collector = CompanionOwnerRequestCollection(profile: profile, transport: transport)
    }
    private struct Costs {
        var bytes = 0, fetches = 0, checked = 0, committed = 0
        func result(retry: Bool = false, failure: (any Error)? = nil) -> CompanionDeviceDrainTurn {
            CompanionDeviceDrainTurn(downloadedBytes: bytes, fetches: fetches, checkedRequests: checked,
                decisionsCommitted: committed, needsRetry: retry, jobFailure: failure)
        }
    }
    public func run(deviceID: String, allowance: CompanionCollectionAllowance,
                    now: @Sendable () -> String,
                    adapter: any CompanionDecisionAdapter & Sendable) async throws -> CompanionDeviceDrainTurn {
        do { return try await locks.withLock(deviceID: deviceID) {
            var costs = Costs()
            let execution = CompanionDecisionExecution(profile: profile)
            do {
                guard allowance.downloadBytes > 0, try admitted(deviceID) else { return costs.result() }
                let initial = try clock(now)
                if let recovered = try execution.recoverPending(deviceID: deviceID, today: initial.day,
                                                                 now: initial.at, adapter: adapter) {
                    if recovered.committed { costs.committed += 1 }
                    try await delete(recovered.outcome.requestID, deviceID, allowance, &costs)
                }
                guard costs.bytes < allowance.downloadBytes else { return costs.result() }
                let collection = try await collector.collect(deviceID: deviceID, today: try clock(now).day,
                    allowance: CompanionCollectionAllowance(downloadBytes: allowance.downloadBytes - costs.bytes,
                        fetches: allowance.fetches, checkedRequests: allowance.checkedRequests))
                costs.bytes += collection.downloadedBytes; costs.fetches = collection.fetches
                costs.checked = collection.checkedRequests
                for request in collection.requests {
                    try Task.checkCancellation()
                    guard costs.bytes < allowance.downloadBytes, try admitted(deviceID) else { break }
                    let time = try clock(now)
                    let decision = try execution.decide(request, today: time.day, now: time.at, adapter: adapter)
                    if decision.committed { costs.committed += 1 }
                    // A failed deletion leaves the durable decision; collection retries deletion without effects.
                    try await delete(decision.outcome.requestID, deviceID, allowance, &costs)
                }
                return costs.result()
            } catch CompanionDeviceDecisionFailure.binderUnavailable {
                return costs.result(retry: true)
            } catch CompanionDecisionError.dailyCap {
                return costs.result()
            } catch {
                return costs.result(failure: error)
            }
        } } catch CompanionOwnerConnectionError.busy {
            // Publication or revocation already owns this device; leave its requests and visit the others.
            return CompanionDeviceDrainTurn(needsRetry: true)
        }
    }
    private func clock(_ now: @Sendable () -> String) throws -> (day: String, at: String) {
        let at = now()
        guard CompanionOwnerRelay.time(at) else { throw CompanionDecisionError.invalid }
        return (String(at.prefix(10)), at)
    }
    private func admitted(_ deviceID: String) throws -> Bool {
        let state = try profile.ownerClaimState()
        guard state == .claimed else { throw CompanionPairingFlowError.ownerUnavailable(state) }
        return try profile.store.read { try profile.record(deviceID, $0)?.state == .active }
    }
    private func delete(_ requestID: String, _ deviceID: String, _ allowance: CompanionCollectionAllowance,
                        _ costs: inout Costs) async throws {
        guard try admitted(deviceID) else { throw CompanionCredentialError.unavailable }
        let remaining = allowance.downloadBytes - costs.bytes
        guard remaining > 0 else { return }
        let reply = try await transport.deleteRequest(deviceID: deviceID, requestID: requestID, downloadLimit: remaining)
        guard reply.receivedBytes >= 0, reply.receivedBytes <= remaining else { throw CompanionRelayError.invalid }
        costs.bytes += reply.receivedBytes
        if reply.status == 401 { try profile.recordClaimState(.checkingRefusal) }
        guard reply.status == 204 else { throw CompanionOwnerConnectionError.relayRejected(reply.status) }
    }
}
