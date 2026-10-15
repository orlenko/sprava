import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class CollectionSecrets: CompanionCredentialStorage, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
}
private func collectionID(_ n: Int) -> String { CompanionWire.base64(Data(repeating: UInt8(n), count: 16)) }
private func collectionEntry(_ n: Int) -> CompanionListedRequest {
    CompanionListedRequest(requestID: collectionID(n), ordinal: Int64(n), receivedAt: "2026-10-15T12:00:00Z")
}
private actor CollectionTransport: RequestCollectionTransport {
    var pages: [CompanionRequestPage]
    var bodies: [String: [CompanionRelayReply<CompanionRequestDownload>]]
    var deletions: [String: [Int]]
    var calls: [String] = []
    let listStatus: Int
    init(_ pages: [CompanionRequestPage], bodies: [String: [CompanionRelayReply<CompanionRequestDownload>]] = [:],
         deletions: [String: [Int]] = [:], listStatus: Int = 200) {
        self.pages = pages; self.bodies = bodies; self.deletions = deletions; self.listStatus = listStatus
    }
    func listRequests(deviceID: String, after: Int64?, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestPage> {
        calls.append("list")
        return CompanionRelayReply(status: listStatus, value: pages.isEmpty ? nil : pages.removeFirst(), receivedBytes: 100)
    }
    func fetchRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestDownload> {
        calls.append("get:" + requestID)
        if let reply = bodies[requestID]?.first { bodies[requestID]?.removeFirst(); return reply }
        return CompanionRelayReply(status: 404, value: nil, receivedBytes: 7)
    }
    func deleteRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<Data> {
        calls.append("delete:" + requestID)
        let status = deletions[requestID]?.isEmpty == false ? deletions[requestID]!.removeFirst() : 204
        return CompanionRelayReply(status: status, value: nil, receivedBytes: status == 204 ? 0 : 7)
    }
    func recorded() -> [String] { calls }
}
private struct CollectionFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-collection-" + UUID().uuidString)
    let secrets = CollectionSecrets()
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    let device = collectionID(79)
    let key = SymmetricKey(data: Data(repeating: 80, count: 32))
    func prepare() throws -> CompanionProfile {
        let p = try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets)
        _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
        try p.store.write { try $0.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'active', 0, 1, 0)", .text(device)) }
        _ = try secrets.insert(account: p.deviceAccount(device), bytes: key.withUnsafeBytes { Data($0) })
        return p
    }
    func body(_ n: Int, sequence: Int64? = nil) throws -> CompanionRelayReply<CompanionRequestDownload> {
        // An authenticated invalid action must still reach a sequence-ordered decision, never be discarded.
        let bytes = try CompanionSealedObject.seal(name: "requests/\(device)/\(collectionID(n))", epoch: 1, key: key,
            plaintext: Data("{\"seq\":\(sequence ?? Int64(n))}".utf8))
        return CompanionRelayReply(status: 200, value: .body(bytes), receivedBytes: bytes.count)
    }
    func collector(_ p: CompanionProfile, _ transport: CollectionTransport) -> CompanionOwnerRequestCollection {
        CompanionOwnerRequestCollection(profile: p, transport: transport)
    }
}

@Test func collectionRefetchesMissingAfterTheLastListingAndSortsAuthenticatedSequencesWithoutApplyingOrDeletingThem() async throws {
    let f = CollectionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let a = try f.body(1, sequence: 2), b = try f.body(2, sequence: 1)
    let transport = CollectionTransport([CompanionRequestPage(requests: [collectionEntry(1), collectionEntry(2), collectionEntry(2)], next: nil)],
        bodies: [collectionID(1): [CompanionRelayReply(status: 404, value: nil, receivedBytes: 7), a], collectionID(2): [b]])
    let result = try await f.collector(p, transport).collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance())
    #expect(result.requests.map(\.sequence) == [1, 2] && result.requests.allSatisfy { $0.action == nil })
    #expect(result.fetches == 3 && result.checkedRequests == 2 && result.downloadedBytes == 107 + a.receivedBytes + b.receivedBytes)
    #expect(await transport.recorded() == ["list", "get:" + collectionID(1), "get:" + collectionID(2), "get:" + collectionID(1)])
    #expect(try p.store.read { try $0.rows("SELECT COUNT(*) FROM request_decisions") } == [[.integer(0)]])
    #expect(try p.store.read { try $0.rows("SELECT COUNT(*) FROM outcome_tombstones") } == [[.integer(0)]])
}

@Test func malformedListingPrefixesCannotConsumeDecisionSlotsAndTheirDiagnosticsStayBounded() async throws {
    let f = CollectionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let pages = (0..<5).map { page -> CompanionRequestPage in
        let entries = (1...25).map { n in CompanionListedRequest(requestID: "malformed-\(page * 25 + n)", ordinal: Int64(page * 25 + n), receivedAt: "2026-10-15T12:00:00Z") }
        return CompanionRequestPage(requests: entries, next: Int64((page + 1) * 25))
    } + [CompanionRequestPage(requests: [collectionEntry(126)], next: nil)]
    let transport = CollectionTransport(pages, bodies: [collectionID(126): [try f.body(126)]])
    let result = try await f.collector(p, transport).collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance())
    #expect(result.requests.map(\.sequence) == [126] && result.checkedRequests == 1 && result.fetches == 1)
    #expect(result.discardedCounts[.badID] == 125 && result.failures.count == 100 && result.failures.allSatisfy { $0.requestID == nil })
    #expect(await transport.recorded().filter { $0.hasPrefix("get:") } == ["get:" + collectionID(126)])
}

@Test func equalAuthenticatedSequencesUseBytewiseRequestIdsRegardlessOfRelayListingOrder() async throws {
    let f = CollectionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let entries = [CompanionListedRequest(requestID: collectionID(2), ordinal: 1, receivedAt: "2026-10-15T12:00:00Z"),
                   CompanionListedRequest(requestID: collectionID(1), ordinal: 2, receivedAt: "2026-10-15T12:00:00Z")]
    let transport = CollectionTransport([CompanionRequestPage(requests: entries, next: nil)], bodies: [
        collectionID(1): [try f.body(1, sequence: 10)], collectionID(2): [try f.body(2, sequence: 10)]])
    let result = try await f.collector(p, transport).collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance())
    #expect(result.requests.map(\.requestID) == [collectionID(1), collectionID(2)])
}

@Test func aFailedConfirmedLostDeletionStopsBeforeLaterDecisionsAndTheNextDrainRetriesDeletionWithoutRefetching() async throws {
    let f = CollectionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let page = CompanionRequestPage(requests: [collectionEntry(1), collectionEntry(2)], next: nil)
    let transport = CollectionTransport([page, page], bodies: [collectionID(2): [try f.body(2), try f.body(2)]], deletions: [collectionID(1): [503, 204]])
    let collector = f.collector(p, transport)
    await #expect(throws: CompanionOwnerConnectionError.relayRejected(503)) {
        try await collector.collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance())
    }
    let result = try await collector.collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance())
    #expect(result.requests.map(\.sequence) == [2])
    let calls = await transport.recorded()
    #expect(calls.filter { $0 == "get:" + collectionID(1) }.count == 2)
    #expect(calls.suffix(3) == ["list", "delete:" + collectionID(1), "get:" + collectionID(2)])
}

@Test func runsOfMissingRequestsProgressAcrossDrainsWithoutExhaustingTheSameFetchBudgetForever() async throws {
    let f = CollectionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let first = CompanionRequestPage(requests: (1...25).map(collectionEntry), next: 25)
    let last = CompanionRequestPage(requests: (26...30).map(collectionEntry), next: nil)
    let transport = CollectionTransport([first, last, first, last, first, last], bodies: [collectionID(30): [try f.body(30)]])
    let collector = f.collector(p, transport)
    for _ in 0..<2 {
        let result = try await collector.collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance())
        #expect(result.requests.isEmpty && result.fetches == 24 && result.lost == 12)
    }
    let result = try await collector.collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance())
    #expect(result.requests.map(\.sequence) == [30] && result.fetches == 11)
    #expect(await transport.recorded().filter { $0 == "get:" + collectionID(1) }.count == 2)
}

@Test func anUnfetchableRequestCutsTheEligiblePrefixAndAnUnconfirmedMissingBodyKeepsLaterWorkBehindIt() async throws {
    let f = CollectionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let page = CompanionRequestPage(requests: (1...4).map(collectionEntry), next: nil)
    let transport = CollectionTransport([page], bodies: [collectionID(2): [try f.body(2)]])
    let result = try await f.collector(p, transport).collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance(fetches: 4))
    #expect(result.requests.map(\.sequence) == [2] && result.fetches == 3 && result.checkedRequests == 1)
    #expect(await transport.recorded().contains("get:" + collectionID(3)) == false)
    let body = try f.body(2), tight = CollectionTransport([CompanionRequestPage(requests: [collectionEntry(1), collectionEntry(2)], next: nil)], bodies: [collectionID(2): [body]])
    let blocked = try await f.collector(p, tight).collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance(downloadBytes: 107 + body.receivedBytes))
    #expect(blocked.requests.isEmpty && blocked.fetches == 2)
}

@Test func duplicateCleanupPrecedesFetchAndPendingDecisionsDailyCapsAndOwnerRefusalStopNetworkWork() async throws {
    let f = CollectionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let request = CompanionAuthenticatedRequest(deviceID: f.device, requestID: collectionID(1), epoch: 1, sequence: 1, action: nil)
    guard case .deciding(let intent) = try p.beginDecision(request, today: "2026-10-15", now: "2026-10-15T12:00:00Z") else { throw CompanionDecisionError.invalid }
    let transport = CollectionTransport([CompanionRequestPage(requests: [collectionEntry(1)], next: nil)]), collector = f.collector(p, transport)
    let pending = try await collector.collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance())
    if case .pendingDecision = pending.stop { } else { Issue.record("Pending recovery must precede collection") }
    #expect(await transport.recorded().isEmpty)
    _ = try p.finishDecision(intent, today: "2026-10-15", decidedAt: "2026-10-15T12:00:00Z")
    let duplicate = try await collector.collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance())
    #expect(duplicate.duplicates == 1 && duplicate.fetches == 0 && duplicate.requests.isEmpty)
    try p.store.write { try $0.execute("UPDATE decision_daily SET count = 500") }
    let capped = try await collector.collect(deviceID: f.device, today: "2026-10-15", allowance: CompanionCollectionAllowance())
    if case .dailyCap = capped.stop { } else { Issue.record("The Mac daily cap must stop collection") }
    #expect(await transport.recorded().count == 2)
    let refused = CollectionTransport([], listStatus: 401), suspended = f.collector(p, refused)
    await #expect(throws: CompanionOwnerConnectionError.relayRejected(401)) {
        try await suspended.collect(deviceID: f.device, today: "2026-10-16", allowance: CompanionCollectionAllowance())
    }
    #expect(try p.ownerClaimState() == .checkingRefusal)
    await #expect(throws: CompanionPairingFlowError.ownerUnavailable(.checkingRefusal)) {
        try await suspended.collect(deviceID: f.device, today: "2026-10-16", allowance: CompanionCollectionAllowance())
    }
    #expect(await refused.recorded().count == 1)
}
