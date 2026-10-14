import Foundation
import CryptoKit
import SpravaKit

public struct CompanionRelayHealth: Sendable { public let instance: String; public let claimed: Bool }
public struct CompanionCreatedPairing: Sendable { public let id: String; public let secret: String; public let expiresAt: String }
public struct CompanionRelayPairing: Sendable {
    public enum State: String, Sendable { case open, joined, keyed, acknowledged }
    public let state: State
    public let deviceID: String?
    public let publicKey: Data?
    public let hello: Data?
}

/// Owner transport only. Claim/pairing state, confirmation and durable effects are the caller's to orchestrate.
public struct CompanionOwnerRelay: Sendable {
    private let relay: CompanionRelayIdentity
    private let token: String
    private let protocolClasses: [AnyClass]?
    public init(relay: CompanionRelayIdentity, token: String) throws {
        try self.init(relay: relay, token: token, protocolClasses: nil)
    }
    init(relay: CompanionRelayIdentity, token: String, protocolClasses: [AnyClass]?) throws {
        guard token.utf8.count == 43, try CompanionWire.decode(token).count == 32 else { throw CompanionRelayError.invalid }
        self.relay = relay; self.token = token; self.protocolClasses = protocolClasses
    }
    func call(_ path: String, limit: Int = 4096, method: String = "GET", body: Data? = nil,
              authenticated: Bool = true, json: Bool = false, downloadLimit: Int? = nil) async throws -> CompanionRelayReply<Data> {
        if let downloadLimit, !(1...8388608).contains(downloadLimit) { throw CompanionRelayError.invalid }
        guard let url = URL(string: relay.origin + path) else { throw CompanionRelayError.invalid }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 30
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        if authenticated { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue(json ? "application/json" : "application/octet-stream", forHTTPHeaderField: "Content-Type") }
        return try await RelayStream(limit: limit, downloadLimit: downloadLimit).send(request, configuration: configuration)
    }
    private func json(_ bytes: Data?) throws -> JSONValue {
        guard let bytes else { throw CompanionRelayError.invalid }
        do {
            let value = try CompanionWire.parse(bytes, limit: 8192)
            guard value.objectValue != nil else { throw CompanionRelayError.invalid }; return value
        } catch { throw CompanionRelayError.invalid }
    }
    private func write(_ entries: [(key: String, value: JSONValue)]) -> Data {
        Data(JSONWriter.compact(.object(JSONObject(entries))).utf8)
    }
    public func health() async throws -> CompanionRelayReply<CompanionRelayHealth> {
        let reply = try await call("/v0/health", authenticated: false)
        guard reply.status == 200 else { return CompanionRelayReply(status: reply.status, value: nil, receivedBytes: reply.receivedBytes) }
        let value = try json(reply.value)
        guard CompanionWire.unsigned(value["protocol"]) == 0, let claimed = value["claimed"]?.boolValue,
              let instance = value["instance"]?.stringValue,
              (try? CompanionRelayIdentity(origin: relay.origin, instance: instance)) != nil else { throw CompanionRelayError.invalid }
        return CompanionRelayReply(status: 200, value: CompanionRelayHealth(instance: instance, claimed: claimed), receivedBytes: reply.receivedBytes)
    }
    /// companion-v0 §6: bytes come from a previously committed vault record; transport does not retry.
    public func claim(_ body: Data) async throws -> Int {
        guard body.count <= 1024 else { throw CompanionRelayError.invalid }
        let value = try json(body)
        guard let setup = value["setup_code"]?.stringValue, CompanionOwnerVault.validSetupCode(setup),
              let hash = value["owner_token_sha256"]?.stringValue, hash.utf8.count == 64,
              hash == SHA256.hash(data: Data(token.utf8)).map({ String(format: "%02x", $0) }).joined() else { throw CompanionRelayError.invalid }
        return try await call("/v0/claim", method: "POST", body: body, authenticated: false, json: true).status
    }
    public func createPairing(deviceID: String, publicKey: Data) async throws -> CompanionRelayReply<CompanionCreatedPairing> {
        guard CompanionWire.isID(deviceID), publicKey.count == 32 else { throw CompanionRelayError.invalid }
        let body = write([("owner_public_key", .string(CompanionWire.base64(publicKey))), ("device_id", .string(deviceID))])
        let reply = try await call("/v0/pairings", method: "POST", body: body, json: true)
        guard reply.status == 200 else { return CompanionRelayReply(status: reply.status, value: nil, receivedBytes: reply.receivedBytes) }
        let value = try json(reply.value)
        guard let id = value["pairing_id"]?.stringValue, CompanionWire.isID(id),
              let secret = value["secret"]?.stringValue, CompanionWire.isID(secret),
              let expires = value["expires_at"]?.stringValue, Self.time(expires) else { throw CompanionRelayError.invalid }
        return CompanionRelayReply(status: 200, value: CompanionCreatedPairing(id: id, secret: secret, expiresAt: expires), receivedBytes: reply.receivedBytes)
    }
    public func pairing(_ id: String) async throws -> CompanionRelayReply<CompanionRelayPairing> {
        guard CompanionWire.isID(id) else { throw CompanionRelayError.invalid }
        let reply = try await call("/v0/pairings/" + id, limit: 8192)
        guard reply.status == 200 else { return CompanionRelayReply(status: reply.status, value: nil, receivedBytes: reply.receivedBytes) }
        let value = try json(reply.value)
        guard let raw = value["state"]?.stringValue, let state = CompanionRelayPairing.State(rawValue: raw) else { throw CompanionRelayError.invalid }
        if state == .open {
            guard value["device_id"] == .null, value["device_public_key"] == .null, value["hello"] == .null else { throw CompanionRelayError.invalid }
            return CompanionRelayReply(status: 200, value: CompanionRelayPairing(state: state, deviceID: nil, publicKey: nil, hello: nil), receivedBytes: reply.receivedBytes)
        }
        guard let device = value["device_id"]?.stringValue, CompanionWire.isID(device),
              let keyText = value["device_public_key"]?.stringValue, let helloText = value["hello"]?.stringValue,
              let key = try? CompanionWire.decode(keyText), key.count == 32,
              let hello = try? CompanionWire.decode(helloText), hello.count <= 2048 else { throw CompanionRelayError.invalid }
        return CompanionRelayReply(status: 200, value: CompanionRelayPairing(state: state, deviceID: device, publicKey: key, hello: hello), receivedBytes: reply.receivedBytes)
    }
    public func deliverKey(pairingID: String, bytes: Data) async throws -> Int {
        guard CompanionWire.isID(pairingID), bytes.count <= 1024 else { throw CompanionRelayError.invalid }
        return try await call("/v0/pairings/" + pairingID + "/key", method: "PUT", body: bytes).status
    }
    public func deletePairing(_ id: String) async throws -> Int {
        guard CompanionWire.isID(id) else { throw CompanionRelayError.invalid }
        return try await call("/v0/pairings/" + id, method: "DELETE").status
    }
    /// companion-v0 §5.2 step 3: once active, read only state; stale transcript fields cannot block acknowledgement.
    public func pairingState(_ id: String) async throws -> CompanionRelayReply<CompanionRelayPairing.State> {
        guard CompanionWire.isID(id) else { throw CompanionRelayError.invalid }
        let reply = try await call("/v0/pairings/" + id, limit: 8192)
        guard reply.status == 200 else { return CompanionRelayReply(status: reply.status, value: nil, receivedBytes: reply.receivedBytes) }
        let value = try json(reply.value)
        guard let raw = value["state"]?.stringValue, let state = CompanionRelayPairing.State(rawValue: raw) else { throw CompanionRelayError.invalid }
        return CompanionRelayReply(status: 200, value: state, receivedBytes: reply.receivedBytes)
    }
    /// Transport for durably recorded owner objects (§9.7). No plaintext metadata may be attached to an envelope.
    public func putObject(name: String, bytes: Data) async throws -> Int {
        do {
            let envelope = try CompanionWire.parse(bytes, limit: 1048576)
            guard let epoch = CompanionWire.unsigned(envelope["e"]) else { throw CompanionRelayError.invalid }
            let b = try CompanionSealedObject.binding(name, epoch)
            guard b.signed, bytes.count <= b.wire, let object = envelope.objectValue, object.entries.count == 6,
                  Set(object.keys) == Set(["v", "kid", "e", "n", "c", "s"]), CompanionWire.unsigned(envelope["v"]) == 0,
                  let kid = envelope["kid"]?.stringValue, kid.utf8.elementsEqual(b.kid.utf8),
                  let nonce = envelope["n"]?.stringValue, try CompanionWire.decode(nonce).count == 12,
                  let cipher = envelope["c"]?.stringValue, let signature = envelope["s"]?.stringValue,
                  try CompanionWire.decode(signature).count == 64 else { throw CompanionRelayError.invalid }
            let c = try CompanionWire.decode(cipher)
            guard c.count >= 16, c.count <= b.plaintext + 16 else { throw CompanionRelayError.invalid }
        } catch { throw CompanionRelayError.invalid }
        return try await call("/v0/objects/" + name, method: "PUT", body: bytes).status
    }
    static func time(_ text: String) -> Bool {
        guard text.utf8.count == 20, text.wholeMatch(of: /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/) != nil,
              text.utf8.allSatisfy({ $0 < 128 }), Timestamp.parse(text) != nil else { return false }
        if text.suffix(3) != "60Z" { return true }
        guard text.suffix(9) == "23:59:60Z", let day = CalendarDate.strict(String(text.prefix(10))) else { return false }
        return day.day == CalendarDate.daysIn(month: day.month, year: day.year)
    }
}
