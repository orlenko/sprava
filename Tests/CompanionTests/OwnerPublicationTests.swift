import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class PublicationSecrets: CompanionCredentialStorage, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
}
private final class PublicationClock: @unchecked Sendable {
    var value = "2026-10-15T12:00:00Z"
}
private actor PublicationTransport: OwnerPublicationTransport {
    var statuses: [Int]
    var calls: [(String, Data)] = []
    let paused: Bool
    var waiter: CheckedContinuation<Void, Never>?
    var response: CheckedContinuation<Int, Never>?
    init(_ statuses: [Int], paused: Bool = false) { self.statuses = statuses; self.paused = paused }
    func putObject(name: String, bytes: Data) async throws -> Int {
        calls.append((name, bytes)); waiter?.resume(); waiter = nil
        if paused { return await withCheckedContinuation { response = $0 } }
        guard !statuses.isEmpty else { throw URLError(.timedOut) }
        return statuses.removeFirst()
    }
    func started() async { if calls.isEmpty { await withCheckedContinuation { waiter = $0 } } }
    func release() { response?.resume(returning: 204); response = nil }
    func recorded() -> [(String, Data)] { calls }
}
private struct PublicationFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-publication-" + UUID().uuidString)
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    let secrets = PublicationSecrets()
    let clock = PublicationClock()
    let local = try! CompanionLocalBinderIdentity(bytes: Data(repeating: 43, count: 16))
    func profile() throws -> CompanionProfile { try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets) }
    func prepare() throws -> (CompanionProfile, String) {
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 19, count: 32).base64EncodedString())
        let p = try profile(); _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
        return (p, try p.showBinder(local).id)
    }
    func publisher(_ p: CompanionProfile, _ transport: PublicationTransport) -> CompanionOwnerPublication {
        CompanionOwnerPublication(profile: p, transport: transport, now: { clock.value })
    }
    func reading() -> CompanionViewReading {
        CompanionViewReading(name: "Sample binder", today: "2026-10-15", generatedAt: clock.value,
            openItems: [.object(JSONObject([("id", .string("item")), ("title", .string("Inspect"))]))])
    }
}

@Test func publicationPacesLostRepliesAcrossRestartAndRetriesTheExactRecordedBytesBeforeIndexing() async throws {
    let f = PublicationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(), view = try p.prepareView(binderID: id, reading: f.reading()).publication
    // An absent scripted response simulates a lost reply after the request was sent.
    let lost = PublicationTransport([])
    do { _ = try await f.publisher(p, lost).uploadView(binderID: id); Issue.record("Expected a lost reply") }
    catch let error as URLError { #expect(error.code == .timedOut) }
    let transport = PublicationTransport([204, 204]), restarted = try f.profile(), publisher = f.publisher(restarted, transport)
    if case .waiting(let name, let next) = try await publisher.uploadView(binderID: id) {
        #expect(name == view.name && next == "2026-10-15T12:00:02Z")
    } else { Issue.record("Restart must honor the recorded retry time") }
    #expect(await transport.recorded().isEmpty)
    f.clock.value = "2026-10-15T12:00:02Z"
    if case .uploaded(let name) = try await publisher.uploadView(binderID: id) { #expect(name == view.name) }
    else { Issue.record("Expected the view upload to finish") }
    _ = try await publisher.uploadIndex(generatedAt: f.clock.value)
    let lostCalls = await lost.recorded(), calls = await transport.recorded()
    #expect(lostCalls.count == 1 && calls.count == 2 && calls[0].0 == view.name && calls[0].1 == lostCalls[0].1)
    #expect(calls[1].0 == "index/1")
    #expect(try p.store.read { try $0.rows("SELECT index_published FROM profile") } == [[.integer(1)]])
}

@Test func conflictsRetireViewAndIndexNamesWithoutRegeneratingOrSendingAnotherObjectInTheSameStep() async throws {
    let f = PublicationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(), first = try p.prepareView(binderID: id, reading: f.reading()).publication
    let transport = PublicationTransport([409, 410, 204]), publisher = f.publisher(p, transport)
    if case .superseded(let name) = try await publisher.uploadView(binderID: id) { #expect(name == first.name) }
    else { Issue.record("Expected a retired view") }
    #expect(try p.pendingView(binderID: id) == nil)
    let second = try p.prepareView(binderID: id, reading: f.reading()).publication
    #expect(second.version == 2)
    if case .superseded(let name) = try await publisher.uploadIndex(generatedAt: f.clock.value) { #expect(name == "index/1") }
    else { Issue.record("Expected a retired index") }
    _ = try await publisher.uploadIndex(generatedAt: f.clock.value)
    let calls = await transport.recorded()
    #expect(calls.map { $0.0 } == [first.name, "index/1", "index/2"])
}

@Test func aSharingRemovalBeforeRestartSupersedesTheOldPendingIndexBeforeAnyUpload() async throws {
    let f = PublicationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(), view = try p.prepareView(binderID: id, reading: f.reading()).publication
    #expect(try p.completeView(view))
    let old = try p.prepareIndex(generatedAt: f.clock.value)
    // Stop after the durable off switch, before the earlier process retired its pending index.
    try p.hideBinder(f.local)
    let transport = PublicationTransport([204]), restarted = try f.profile()
    _ = try await f.publisher(restarted, transport).uploadIndex(generatedAt: f.clock.value)
    let calls = await transport.recorded()
    #expect(calls.count == 1 && calls[0].0 == "index/2" && calls[0].1 != old.bytes)
    let account = try #require(try p.currentAccount()), owner = try #require(try CompanionOwnerVault(backend: f.secrets).load(f.relay))
    let payload = try CompanionSealedObject.open(name: calls[0].0, epoch: 1, key: account.key, bytes: calls[0].1, owner: owner.signingKey.publicKey)
    #expect(payload["binders"] == .array([]))
    #expect(try p.completeIndex(old) == false)
}

@Test func anOwnerRefusalIsRecordedBeforeReturningAndRestartMakesNoMoreOwnerCalls() async throws {
    let f = PublicationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(); _ = try p.prepareView(binderID: id, reading: f.reading())
    let transport = PublicationTransport([401]), publisher = f.publisher(p, transport)
    do { _ = try await publisher.uploadView(binderID: id); Issue.record("Expected refusal") }
    catch CompanionOwnerConnectionError.relayRejected(401) { }
    #expect(try f.profile().ownerClaimState() == .checkingRefusal)
    do { _ = try await f.publisher(try f.profile(), transport).uploadIndex(generatedAt: f.clock.value); Issue.record("Expected suspended owner") }
    catch CompanionPairingFlowError.ownerUnavailable(.checkingRefusal) { }
    #expect(await transport.recorded().count == 1)
}

@Test func theUploadLockRejectsOverlappingCallsAndRemovalAndALateViewCannotBecomeIndexed() async throws {
    let f = PublicationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(); _ = try p.prepareView(binderID: id, reading: f.reading())
    let transport = PublicationTransport([], paused: true), publisher = f.publisher(p, transport)
    let pending = Task { try await publisher.uploadView(binderID: id) }
    await transport.started()
    do { _ = try await publisher.uploadIndex(generatedAt: f.clock.value); Issue.record("Expected busy publisher") }
    catch CompanionOwnerConnectionError.busy { }
    do { try await publisher.hideBinder(f.local); Issue.record("Expected busy removal") }
    catch CompanionOwnerConnectionError.busy { }
    #expect(try p.binderSharing(f.local)?.state == .shown)
    let newest = try p.prepareView(binderID: id, reading: f.reading()).publication
    await transport.release()
    if case .superseded = try await pending.value { } else { Issue.record("Late completion must be superseded") }
    #expect(try p.pendingView(binderID: id)?.bytes == newest.bytes)
    try await publisher.hideBinder(f.local)
    #expect(try p.binderSharing(f.local) == nil)
}

@Test func repeatedFailuresPersistIncreasingRetryDelaysAndCapThemAcrossRestart() async throws {
    let f = PublicationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(), view = try p.prepareView(binderID: id, reading: f.reading()).publication
    let transport = PublicationTransport(Array(repeating: 503, count: 6))
    let seconds = ["02", "07", "17", "37"]
    let retryTimes = seconds.map { "2026-10-15T12:00:" + $0 + "Z" } + ["2026-10-15T12:01:07Z", "2026-10-15T12:01:37Z"]
    for next in retryTimes {
        let publisher = f.publisher(try f.profile(), transport)
        do { _ = try await publisher.uploadView(binderID: id); Issue.record("Expected relay failure") }
        catch CompanionOwnerConnectionError.relayRejected(503) { }
        if case .waiting(_, let retryAt) = try await f.publisher(try f.profile(), transport).uploadView(binderID: id) {
            #expect(retryAt == next)
        } else { Issue.record("Expected durable pacing") }
        f.clock.value = next
    }
    let calls = await transport.recorded()
    #expect(calls.count == 6 && calls.allSatisfy { $0.0 == view.name && $0.1 == view.bytes })
}

@Test func anEpochHeldByARevokedRecipientCannotUploadEvenAPreviouslyPreparedIndex() async throws {
    let f = PublicationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, _) = try f.prepare(), index = try p.prepareIndex(generatedAt: f.clock.value)
    let device = CompanionWire.base64(Data(repeating: 44, count: 16))
    try p.store.write { t in
        try t.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'revoked', 0, 1, 0)", .text(device))
        try t.execute("INSERT INTO recipients VALUES (1, ?)", .text(device))
    }
    let transport = PublicationTransport([204])
    do { _ = try await f.publisher(p, transport).uploadIndex(generatedAt: f.clock.value); Issue.record("Expected blocked epoch") }
    catch CompanionPublicationError.unavailable { }
    #expect(await transport.recorded().isEmpty)
    #expect(try p.pendingIndex()?.bytes == index.bytes)
}
