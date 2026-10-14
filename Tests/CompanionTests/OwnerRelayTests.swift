import Foundation
import CryptoKit
import Testing
@testable import Companion
import SpravaKit

private struct HTTPPlan: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    var hold = false
    var observe: @Sendable (URLRequest) -> Void = { _ in }
}
private actor RequestStarted {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { started = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
private final class HTTPPlans: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [String: HTTPPlan] = [:]
    func set(_ host: String, _ plan: HTTPPlan) { lock.lock(); defer { lock.unlock() }; plans[host] = plan }
    func get(_ host: String) -> HTTPPlan? { lock.lock(); defer { lock.unlock() }; return plans[host] }
}
private final class InventedRelayProtocol: URLProtocol, @unchecked Sendable {
    static let plans = HTTPPlans()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let plan = Self.plans.get(url.host!) else {
            client?.urlProtocol(self, didFailWithError: CompanionRelayError.invalid); return
        }
        plan.observe(request)
        if plan.hold { return }
        let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: plan.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private let ownerToken = CompanionWire.base64(Data(repeating: 13, count: 32))
private let wireID = CompanionWire.base64(Data(repeating: 8, count: 16))
private let relayInstance = "fedcba9876543210fedcba9876543210"
private func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open(); defer { stream.close() }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
    while result.count <= 4096 {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { return nil }
        if count == 0 { return result }
        result.append(contentsOf: buffer.prefix(count))
    }
    return nil
}
private func owner(_ plan: HTTPPlan) throws -> (CompanionOwnerRelay, String) {
    let host = UUID().uuidString.lowercased() + ".example"
    InventedRelayProtocol.plans.set(host, plan)
    let identity = try CompanionRelayIdentity(origin: "https://" + host, instance: relayInstance)
    return (try CompanionOwnerRelay(relay: identity, token: ownerToken, protocolClasses: [InventedRelayProtocol.self]), host)
}

@Test func ownerMailboxValidatesDevicePagesAndUsesOnlyCanonicalSameOriginCursors() async throws {
    let body = Data("{\"devices\":[{\"device_id\":\"\(wireID)\",\"state\":\"active\",\"paired_at\":\"2026-10-15T12:00:00Z\",\"last_seen\":null}],\"next\":\"\(wireID)\"}".utf8)
    let (client, host) = try owner(HTTPPlan(chunks: [body], observe: { request in
        #expect(request.url?.path == "/v0/devices" && request.url?.query == "limit=50")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + ownerToken)
    }))
    let reply = try await client.listDevices(downloadLimit: 8388608)
    #expect(reply.receivedBytes == body.count && reply.value?.devices.first?.deviceID == wireID && reply.value?.next == wireID)
    #expect(reply.value?.devices.first?.state == .active && reply.value?.devices.first?.lastSeen == nil)
    InventedRelayProtocol.plans.set(host, HTTPPlan(chunks: [Data("{\"devices\":[],\"next\":null}".utf8)], observe: { request in
        #expect(request.url?.query == "limit=50&after=" + wireID)
    }))
    #expect(try await client.listDevices(after: wireID, downloadLimit: 16384).value?.devices.isEmpty == true)
    await #expect(throws: CompanionRelayError.invalid) { try await client.listDevices(after: "../credential", downloadLimit: 16384) }
    for bad in ["{\"devices\":[],\"next\":\"\(wireID)\"}",
                "{\"devices\":[{\"device_id\":\"\(wireID)\",\"state\":\"active\",\"paired_at\":null,\"last_seen\":null}],\"next\":null}"] {
        InventedRelayProtocol.plans.set(host, HTTPPlan(chunks: [Data(bad.utf8)]))
        await #expect(throws: CompanionRelayError.invalid) { try await client.listDevices(after: wireID, downloadLimit: 16384) }
    }
}

@Test func ownerRequestPagesKeepEqualOrdinalsAndBadIdsForTheDrainsDiscardCheckButRejectBackwardCursors() async throws {
    let entry = "{\"request_id\":\"\(wireID)\",\"ordinal\":7,\"received_at\":\"2026-10-15T12:00:00Z\"}"
    let badID = "{\"request_id\":\"../credentials\",\"ordinal\":7,\"received_at\":\"2026-10-15T12:00:00Z\"}"
    // A page may exceed limit=25 to keep all equal ordinals together (§7.6).
    let body = Data(("{\"requests\":[" + Array(repeating: entry, count: 25).joined(separator: ",") + "," + badID + "],\"next\":7}").utf8)
    let (client, host) = try owner(HTTPPlan(chunks: [body], observe: { request in
        #expect(request.url?.path == "/v0/requests/" + wireID && request.url?.query == "limit=25&after=6")
    }))
    let reply = try await client.listRequests(deviceID: wireID, after: 6, downloadLimit: 16384)
    #expect(reply.receivedBytes == body.count && reply.value?.requests.count == 26 && reply.value?.next == 7)
    #expect(reply.value?.requests.last?.requestID == "../credentials")
    for bad in ["{\"requests\":[\(entry)],\"next\":6}", "{\"requests\":[],\"next\":7}",
                "{\"requests\":[\(entry)],\"next\":9007199254740992}"] {
        InventedRelayProtocol.plans.set(host, HTTPPlan(chunks: [Data(bad.utf8)]))
        await #expect(throws: CompanionRelayError.invalid) { try await client.listRequests(deviceID: wireID, after: 6, downloadLimit: 16384) }
    }
    InventedRelayProtocol.plans.set(host, HTTPPlan(chunks: [Data("{\"requests\":[\(entry)],\"next\":null}".utf8)]))
    await #expect(throws: CompanionRelayError.invalid) { try await client.listRequests(deviceID: wireID, after: 7, downloadLimit: 16384) }
}

@Test func mailboxCallsCountErrorBytesAndEnforceTheRemainingBudgetWhileStreaming() async throws {
    let bytes = Data("refused".utf8)
    let (client, host) = try owner(HTTPPlan(status: 401, chunks: [bytes]))
    let reply = try await client.listRequests(deviceID: wireID, downloadLimit: bytes.count)
    #expect(reply.status == 401 && reply.value == nil && reply.receivedBytes == bytes.count)
    await #expect(throws: CompanionRelayError.invalid) { try await client.listRequests(deviceID: wireID, downloadLimit: bytes.count - 1) }
    for budget in [0, -1, 8388609] {
        await #expect(throws: CompanionRelayError.invalid) { try await client.listDevices(downloadLimit: budget) }
    }
    InventedRelayProtocol.plans.set(host, HTTPPlan(chunks: [Data(repeating: 32, count: 16384), Data([32])]))
    await #expect(throws: CompanionRelayError.invalid) { try await client.listRequests(deviceID: wireID, downloadLimit: 8388608) }
    InventedRelayProtocol.plans.set(host, HTTPPlan(chunks: [Data(repeating: 32, count: 8), Data(repeating: 32, count: 3)]))
    await #expect(throws: CompanionRelayError.invalid) { try await client.listDevices(downloadLimit: 10) }
}

@Test func mailboxDeletesValidateIdsBeforeSendingAndReturnStatusAndDownloadCost() async throws {
    let (client, host) = try owner(HTTPPlan(status: 204, observe: { request in
        #expect(request.httpMethod == "DELETE" && request.url?.path == "/v0/requests/" + wireID + "/" + wireID)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + ownerToken)
    }))
    let deleted = try await client.deleteRequest(deviceID: wireID, requestID: wireID, downloadLimit: 4096)
    #expect(deleted.status == 204 && deleted.receivedBytes == 0)
    await #expect(throws: CompanionRelayError.invalid) { try await client.deleteRequest(deviceID: wireID, requestID: "../credential", downloadLimit: 4096) }
    InventedRelayProtocol.plans.set(host, HTTPPlan(status: 503, chunks: [Data("failure".utf8)], observe: { request in
        #expect(request.httpMethod == "DELETE" && request.url?.path == "/v0/devices/" + wireID)
    }))
    let failed = try await client.deleteDevice(deviceID: wireID, downloadLimit: 4096)
    #expect(failed.status == 503 && failed.value == nil && failed.receivedBytes == 7)
    await #expect(throws: CompanionRelayError.invalid) { try await client.deleteDevice(deviceID: "https://other.example", downloadLimit: 4096) }
}

@Test func ownerHealthReadsOnlyStrictBoundedMetadataWithoutCredentials() async throws {
    let bytes = Data("{\"protocol\":0,\"claimed\":true,\"instance\":\"\(relayInstance)\"}".utf8)
    let (client, _) = try owner(HTTPPlan(chunks: [bytes.prefix(13), bytes.dropFirst(13)], observe: { request in
        #expect(request.url?.path == "/v0/health")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Referer") == nil)
        #expect(!request.httpShouldHandleCookies)
    }))
    let reply = try await client.health()
    #expect(reply.status == 200 && reply.value?.instance == relayInstance && reply.value?.claimed == true)
}

@Test func ownerRejectsOversizedStreamsHeadersErrorBodiesRedirectsAndMalformedJSON() async throws {
    for plan in [HTTPPlan(headers: ["Content-Length": "4097"]), HTTPPlan(chunks: [Data(repeating: 32, count: 2048), Data(repeating: 32, count: 2049)]),
                 HTTPPlan(status: 503, chunks: [Data(repeating: 32, count: 4097)]),
                 HTTPPlan(status: 302, headers: ["Location": "https://other.example"]),
                 HTTPPlan(chunks: [Data("{\"protocol\":0,\"protocol\":0}".utf8)]),
                 HTTPPlan(chunks: [Data("{\"protocol\":0,\"claimed\":true,\"instance\":\"../x\"}".utf8)])] {
        let (client, _) = try owner(plan)
        await #expect(throws: CompanionRelayError.invalid) { try await client.health() }
    }
    let (client, _) = try owner(HTTPPlan(status: 503, chunks: [Data("private error text".utf8)]))
    let reply = try await client.health()
    #expect(reply.status == 503 && reply.value == nil)
}

@Test func ownerPairingCallsBindTokenAndValidateResponseFields() async throws {
    let body = Data("{\"pairing_id\":\"\(wireID)\",\"secret\":\"\(wireID)\",\"expires_at\":\"2026-10-15T12:00:00Z\"}".utf8)
    let (client, host) = try owner(HTTPPlan(chunks: [body], observe: { request in
        #expect(request.httpMethod == "POST" && request.url?.path == "/v0/pairings")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + ownerToken)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(requestBody(request) == Data("{\"owner_public_key\":\"\(CompanionWire.base64(Data(repeating: 10, count: 32)))\",\"device_id\":\"\(wireID)\"}".utf8))
    }))
    let made = try await client.createPairing(deviceID: wireID, publicKey: Data(repeating: 10, count: 32))
    #expect(made.value?.id == wireID && made.value?.secret == wireID)
    InventedRelayProtocol.plans.set(host, HTTPPlan(chunks: [Data("{\"state\":\"open\",\"device_id\":null,\"device_public_key\":null,\"hello\":null}".utf8)]))
    #expect(try await client.pairing(wireID).value?.state == .open)
    let key = CompanionWire.base64(Data(repeating: 1, count: 32)), hello = CompanionWire.base64(Data([1, 2, 3]))
    InventedRelayProtocol.plans.set(host, HTTPPlan(chunks: [Data("{\"state\":\"joined\",\"device_id\":\"\(wireID)\",\"device_public_key\":\"\(key)\",\"hello\":\"\(hello)\"}".utf8)]))
    let joined = try await client.pairing(wireID)
    #expect(joined.value?.deviceID == wireID && joined.value?.hello == Data([1, 2, 3]))
    InventedRelayProtocol.plans.set(host, HTTPPlan(status: 204, observe: { request in
        #expect(request.url?.path == "/v0/pairings/" + wireID + "/key")
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    }))
    #expect(try await client.deliverKey(pairingID: wireID, bytes: Data([1])) == 204)
    InventedRelayProtocol.plans.set(host, HTTPPlan(status: 204, observe: { request in #expect(request.httpMethod == "DELETE") }))
    #expect(try await client.deletePairing(wireID) == 204)
}

@Test func invalidOwnerInputsCannotMakeRequestsAndCancellationStopsAStalledResponse() async throws {
    let (client, _) = try owner(HTTPPlan(hold: true))
    await #expect(throws: CompanionRelayError.invalid) { try await client.pairing("../x") }
    await #expect(throws: CompanionRelayError.invalid) { try await client.deliverKey(pairingID: wireID, bytes: Data(repeating: 0, count: 1025)) }
    await #expect(throws: CompanionRelayError.invalid) { try await client.createPairing(deviceID: wireID, publicKey: Data()) }
    await #expect(throws: CompanionRelayError.invalid) { try await client.claim(Data("{}".utf8)) }
    let pending = Task { try await client.health() }
    pending.cancel()
    await #expect(throws: CompanionRelayError.invalid) { try await pending.value }
    #expect(CompanionOwnerRelay.time("2026-06-30T23:59:60Z"))
    #expect(!CompanionOwnerRelay.time("2026-06-29T23:59:60Z"))
    #expect(!CompanionOwnerRelay.time("2026-10-15T12:00:60Z"))
}

@Test func claimSendsPreviouslyRecordedExactBytesWithNoBearer() async throws {
    let setup = Data(repeating: 15, count: 32).base64EncodedString()
    let hash = SHA256.hash(data: Data(ownerToken.utf8)).map { String(format: "%02x", $0) }.joined()
    let body = Data("{\"setup_code\":\"\(setup)\",\"owner_token_sha256\":\"\(hash)\"}".utf8)
    let (client, _) = try owner(HTTPPlan(status: 204, observe: { request in
        #expect(request.httpMethod == "POST" && request.url?.path == "/v0/claim")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requestBody(request) == body)
    }))
    #expect(try await client.claim(body) == 204)
}

@Test func aStartedRelayCallCanBeCancelledAndTheTotalDeadlineDoesNotDependOnThePeer() async throws {
    let signal = RequestStarted()
    let (client, host) = try owner(HTTPPlan(hold: true, observe: { _ in Task { await signal.signal() } }))
    let pending = Task { try await client.health() }
    await signal.wait()
    pending.cancel()
    await #expect(throws: CompanionRelayError.invalid) { try await pending.value }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [InventedRelayProtocol.self]
    let request = URLRequest(url: URL(string: "https://" + host + "/v0/health")!)
    let began = ContinuousClock.now
    await #expect(throws: CompanionRelayError.invalid) {
        try await RelayStream(limit: 4096).send(request, configuration: configuration, deadline: .milliseconds(100))
    }
    #expect(began.duration(to: .now) < .seconds(5))
}

@Test func recordedOwnerObjectsUploadExactCiphertextAndRefuseUnsignedOrPlaintextExtensions() async throws {
    let keys = SymmetricKey(size: .bits256), signer = Curve25519.Signing.PrivateKey()
    let name = "devices/\(wireID)/keys/1"
    let bytes = try CompanionSealedObject.seal(name: name, epoch: 1, key: keys, plaintext: Data("{}".utf8), signer: signer)
    let (client, host) = try owner(HTTPPlan(status: 204, observe: { request in
        #expect(request.url?.path == "/v0/objects/" + name && request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + ownerToken)
        #expect(requestBody(request) == bytes)
    }))
    #expect(try await client.putObject(name: name, bytes: bytes) == 204)
    InventedRelayProtocol.plans.set(host, HTTPPlan(hold: true))
    await #expect(throws: CompanionRelayError.invalid) { try await client.putObject(name: "../keys/1", bytes: bytes) }
    let unsigned = try CompanionSealedObject.seal(name: "devices/\(wireID)/revocation", epoch: 0, key: keys, plaintext: Data("{}".utf8))
    await #expect(throws: CompanionRelayError.invalid) { try await client.putObject(name: "devices/\(wireID)/revocation", bytes: unsigned) }
    var object = try #require(try CompanionWire.parse(bytes, limit: 4096).objectValue)
    object.entries.append(("title", .string("Invented private title")))
    let leaked = Data(JSONWriter.compact(.object(object)).utf8)
    await #expect(throws: CompanionRelayError.invalid) { try await client.putObject(name: name, bytes: leaked) }
}

@Test func activePairingStatusIgnoresUnusedTranscriptFieldsButStillUsesStrictJSON() async throws {
    let (client, host) = try owner(HTTPPlan(chunks: [Data("{\"state\":\"acknowledged\",\"device_id\":null,\"device_public_key\":\"invalid\",\"hello\":17}".utf8)]))
    #expect(try await client.pairingState(wireID).value == .acknowledged)
    await #expect(throws: CompanionRelayError.invalid) { try await client.pairing(wireID) }
    InventedRelayProtocol.plans.set(host, HTTPPlan(chunks: [Data("{\"state\":\"joined\",\"state\":\"acknowledged\"}".utf8)]))
    await #expect(throws: CompanionRelayError.invalid) { try await client.pairingState(wireID) }
}
