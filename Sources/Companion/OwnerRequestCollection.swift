import Foundation
import SpravaKit

/// companion-v0 §§9.2–9.4: bounded collection only, never a binder effect or an authenticated request deletion.
/// One collector per profile retains confirmed-lost knowledge between drains (at most 1,000 names/device).
/// Caller holds this device's decision lock through collection, ordered decisions, and their subsequent deletes.
/// Visit active devices fairly; subtract returned costs from the shared drain allowance before the next device.
public actor CompanionOwnerRequestCollection {
    private let profile: CompanionProfile
    private let transport: any RequestCollectionTransport
    private var busy = false
    private struct Remembered { let ordinal: Int64; var deleted: Bool }
    private var memory: [String: [String: Remembered]] = [:]
    private var deviceOrder: [String] = []
    public init(profile: CompanionProfile) throws {
        guard let owner = try CompanionOwnerVault(backend: profile.secrets).load(profile.relay) else { throw CompanionCredentialError.unavailable }
        self.profile = profile; transport = try CompanionOwnerRelay(relay: profile.relay, token: owner.ownerToken)
    }
    init(profile: CompanionProfile, transport: any RequestCollectionTransport) { self.profile = profile; self.transport = transport }
    /// A revocation discards its ephemeral lost knowledge under the same device decision lock.
    public func forgetDevice(_ deviceID: String) throws {
        guard !busy else { throw CompanionOwnerConnectionError.busy }
        memory.removeValue(forKey: deviceID); deviceOrder.removeAll { $0 == deviceID }
    }
    private struct Missing { let entry: CompanionListedRequest; let position: Int; var hasLater = false }
    private final class Work {
        let allowance: CompanionCollectionAllowance
        var bytes = 0, fetches = 0, checked = 0, duplicates = 0, lost = 0
        var reservations = 0, position = 0
        var requests: [(Int, CompanionAuthenticatedRequest)] = []
        var failures: [CompanionCollectionFailure] = []
        var discardedCounts: [CompanionRequestAdmission.Discard: Int] = [:]
        var missing: [Missing] = []
        var seen = Set<String>()
        var blocked = false
        init(_ allowance: CompanionCollectionAllowance) { self.allowance = allowance }
        var remaining: Int { allowance.downloadBytes - bytes }
        var canFetch: Bool { fetches + reservations + 2 <= min(25, allowance.fetches) }
        var canCheck: Bool { checked + reservations < min(25, allowance.checkedRequests) }
        func discard(_ reason: CompanionRequestAdmission.Discard, requestID: String?) {
            discardedCounts[reason, default: 0] += 1
            if failures.count == 100 { failures.removeFirst() }
            failures.append(CompanionCollectionFailure(requestID: requestID, reason: reason))
        }
    }
    public func collect(deviceID: String, today: String, allowance: CompanionCollectionAllowance) async throws -> CompanionCollectedRequests {
        guard !busy else { throw CompanionOwnerConnectionError.busy }
        guard CompanionWire.isID(deviceID), CalendarDate.strict(today) != nil else { throw CompanionRelayError.invalid }
        busy = true; defer { busy = false }
        let state = try profile.ownerClaimState()
        guard state == .claimed else { throw CompanionPairingFlowError.ownerUnavailable(state) }
        let work = Work(allowance)
        guard try profile.store.read({ try profile.record(deviceID, $0)?.state == .active }) else {
            memory.removeValue(forKey: deviceID); deviceOrder.removeAll { $0 == deviceID }
            return result(work, .inactive)
        }
        guard try profile.pendingDecision(deviceID: deviceID) == nil else { return result(work, .pendingDecision) }
        guard try profile.store.read({ try profile.decisionsToday(deviceID, today, $0) }) < 500 else { return result(work, .dailyCap) }
        if !deviceOrder.contains(deviceID) {
            // The relay admits at most 20 devices. Bound memory even across many local pairing/revocation cycles.
            if deviceOrder.count == 20 { memory.removeValue(forKey: deviceOrder.removeFirst()) }
            deviceOrder.append(deviceID)
        }
        var after: Int64?
        for pageNumber in 0..<40 {
            guard work.remaining > 0 else { work.blocked = true; break }
            let reply = try await transport.listRequests(deviceID: deviceID, after: after, downloadLimit: work.remaining)
            try count(reply, work)
            guard reply.status == 200, let page = reply.value else { throw CompanionOwnerConnectionError.relayRejected(reply.status) }
            prune(deviceID, page: page, after: after)
            for entry in page.requests {
                work.position += 1
                if CompanionWire.isID(entry.requestID) {
                    for i in work.missing.indices where work.missing[i].entry.requestID != entry.requestID {
                        work.missing[i].hasLater = true
                    }
                } else {
                    // A malformed name cannot identify a device request. Charge its page/download and bounded
                    // diagnostics, never a fetch/decision slot: a persistent malformed prefix must not starve actions.
                    work.discard(.badID, requestID: nil); continue
                }
                if !work.seen.insert(entry.requestID).inserted { continue }
                if let remembered = memory[deviceID]?[entry.requestID] {
                    if !remembered.deleted {
                        try await delete(deviceID, entry.requestID, work)
                        memory[deviceID]?[entry.requestID]?.deleted = true
                    }
                    continue
                }
                if work.blocked { continue }
                guard work.canCheck else { work.blocked = true; continue }
                if case .decided = try profile.decisionStatus(deviceID: deviceID, requestID: entry.requestID) {
                    work.checked += 1; work.duplicates += 1; try await delete(deviceID, entry.requestID, work); continue
                }
                guard work.canFetch, work.remaining > 0 else { work.blocked = true; continue }
                work.fetches += 1
                let body = try await transport.fetchRequest(deviceID: deviceID, requestID: entry.requestID, downloadLimit: work.remaining)
                try count(body, work)
                if body.status == 404 {
                    work.reservations += 1; work.missing.append(Missing(entry: entry, position: work.position))
                } else { try await admit(body, deviceID, entry, position: work.position, work) }
            }
            if work.blocked && work.missing.isEmpty { break }
            guard let next = page.next else { break }
            after = next
            if pageNumber == 39 { work.blocked = true }
        }
        // Every first 404 reserved this second call. Never expose later requests before it is confirmed.
        for missing in work.missing {
            guard work.remaining > 0 else {
                work.requests.removeAll { $0.0 >= missing.position }; work.blocked = true; break
            }
            work.reservations -= 1; work.fetches += 1
            let body = try await transport.fetchRequest(deviceID: deviceID, requestID: missing.entry.requestID, downloadLimit: work.remaining)
            try count(body, work)
            if body.status == 404 {
                work.lost += 1
                if missing.hasLater {
                    remember(deviceID, missing.entry)
                    try await delete(deviceID, missing.entry.requestID, work)
                    memory[deviceID]?[missing.entry.requestID]?.deleted = true
                }
            } else { try await admit(body, deviceID, missing.entry, position: missing.position, work) }
        }
        return result(work, work.blocked ? .budget : .complete)
    }
    private func admit(_ reply: CompanionRelayReply<CompanionRequestDownload>, _ deviceID: String, _ entry: CompanionListedRequest,
                       position: Int, _ work: Work) async throws {
        guard reply.status == 200, let download = reply.value else { throw CompanionOwnerConnectionError.relayRejected(reply.status) }
        work.checked += 1
        let admission: CompanionRequestAdmission
        switch download {
        case .tooLarge: admission = .discarded(.tooLarge)
        case .body(let bytes): admission = try profile.admitRequest(deviceID: deviceID, requestID: entry.requestID, bytes: bytes)
        }
        switch admission {
        case .authenticated(let request): work.requests.append((position, request))
        case .discarded(let reason):
            work.discard(reason, requestID: entry.requestID)
            try await delete(deviceID, entry.requestID, work)
        }
    }
    private func delete(_ deviceID: String, _ requestID: String, _ work: Work) async throws {
        guard work.remaining > 0 else { throw CompanionRelayError.invalid }
        let reply = try await transport.deleteRequest(deviceID: deviceID, requestID: requestID, downloadLimit: work.remaining)
        try count(reply, work)
        guard reply.status == 204 else { throw CompanionOwnerConnectionError.relayRejected(reply.status) }
    }
    private func count<T>(_ reply: CompanionRelayReply<T>, _ work: Work) throws {
        guard reply.receivedBytes >= 0, reply.receivedBytes <= work.remaining else { throw CompanionRelayError.invalid }
        work.bytes += reply.receivedBytes
        if reply.status == 401 {
            try profile.recordClaimState(.checkingRefusal)
            throw CompanionOwnerConnectionError.relayRejected(401)
        }
    }
    private func result(_ work: Work, _ stop: CompanionCollectedRequests.Stop) -> CompanionCollectedRequests {
        let sorted = work.requests.sorted { a, b in
            if a.1.sequence != b.1.sequence { return a.1.sequence < b.1.sequence }
            return a.1.requestID.utf8.lexicographicallyPrecedes(b.1.requestID.utf8)
        }.map { $0.1 }
        return CompanionCollectedRequests(requests: sorted, failures: work.failures, discardedCounts: work.discardedCounts, duplicates: work.duplicates, lost: work.lost,
            downloadedBytes: work.bytes, fetches: work.fetches, checkedRequests: work.checked, stop: stop)
    }
    private func remember(_ deviceID: String, _ entry: CompanionListedRequest) {
        var entries = memory[deviceID] ?? [:]
        if entries.count >= 1000, entries[entry.requestID] == nil, let oldest = entries.min(by: { $0.value.ordinal < $1.value.ordinal })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[entry.requestID] = Remembered(ordinal: entry.ordinal, deleted: false); memory[deviceID] = entries
    }
    private func prune(_ deviceID: String, page: CompanionRequestPage, after: Int64?) {
        let upper = page.next == nil ? JSONNumber.maxSafeInteger : (page.requests.last?.ordinal ?? (after ?? 0))
        let present = Set(page.requests.map { $0.requestID })
        memory[deviceID] = memory[deviceID]?.filter { key, value in
            !(value.ordinal > (after ?? 0) && value.ordinal <= upper && !present.contains(key))
        }
    }
}
