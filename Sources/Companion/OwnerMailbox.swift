import Foundation
import SpravaKit

public struct CompanionListedDevice: Sendable {
    public enum State: String, Sendable { case pending, active, revoked }
    public let deviceID: String
    public let state: State
    public let pairedAt: String?
    public let lastSeen: String?
}
public struct CompanionDevicePage: Sendable {
    public let devices: [CompanionListedDevice]
    public let next: String?
}
public struct CompanionListedRequest: Sendable {
    /// Untrusted text, not yet an id. The drain's bad-id check (§9.3) precedes fetching or deleting.
    public let requestID: String
    public let ordinal: Int64
    public let receivedAt: String
}
public struct CompanionRequestPage: Sendable {
    public let requests: [CompanionListedRequest]
    public let next: Int64?
}

/// companion-v0 §§7.4, 7.6, 9.2: one bounded HTTP call; no reconciliation, decisions or retries here.
/// `downloadLimit` is the remaining drain budget. Subtract `receivedBytes` after every reply, even an error.
/// A throw stops the drain: a partial, oversized or invalid response must never allow further downloading.
extension CompanionOwnerRelay {
    public func listDevices(after: String? = nil, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionDevicePage> {
        if let after, !CompanionWire.isID(after) { throw CompanionRelayError.invalid }
        let path = "/v0/devices?limit=50" + (after.map { "&after=" + $0 } ?? "")
        let reply = try await call(path, limit: 16384, downloadLimit: downloadLimit)
        guard reply.status == 200 else { return CompanionRelayReply(status: reply.status, value: nil, receivedBytes: reply.receivedBytes) }
        let value = try mailboxJSON(reply.value)
        guard let entries = value["devices"]?.arrayValue, entries.count <= 50 else { throw CompanionRelayError.invalid }
        var previous = after
        let devices = try entries.map { entry -> CompanionListedDevice in
            guard let id = entry["device_id"]?.stringValue, CompanionWire.isID(id),
                  previous == nil || previous!.utf8.lexicographicallyPrecedes(id.utf8),
                  let state = entry["state"]?.stringValue, let parsed = CompanionListedDevice.State(rawValue: state) else { throw CompanionRelayError.invalid }
            previous = id
            return CompanionListedDevice(deviceID: id, state: parsed, pairedAt: try mailboxTime(entry["paired_at"]), lastSeen: try mailboxTime(entry["last_seen"]))
        }
        let next: String?
        if value["next"] == .null { next = nil }
        else {
            guard let id = value["next"]?.stringValue, !devices.isEmpty, id == previous else { throw CompanionRelayError.invalid }; next = id
        }
        return CompanionRelayReply(status: 200, value: CompanionDevicePage(devices: devices, next: next), receivedBytes: reply.receivedBytes)
    }
    public func listRequests(deviceID: String, after: Int64? = nil, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestPage> {
        guard CompanionWire.isID(deviceID), after == nil || (after! >= 0 && after! <= JSONNumber.maxSafeInteger) else { throw CompanionRelayError.invalid }
        let path = "/v0/requests/" + deviceID + "?limit=25" + (after.map { "&after=" + String($0) } ?? "")
        let reply = try await call(path, limit: 16384, downloadLimit: downloadLimit)
        guard reply.status == 200 else { return CompanionRelayReply(status: reply.status, value: nil, receivedBytes: reply.receivedBytes) }
        let value = try mailboxJSON(reply.value)
        guard let entries = value["requests"]?.arrayValue else { throw CompanionRelayError.invalid }
        var previous = after ?? 0
        let requests = try entries.map { entry -> CompanionListedRequest in
            guard let id = entry["request_id"]?.stringValue, let ordinal = CompanionWire.unsigned(entry["ordinal"]),
                  ordinal >= 1, ordinal > (after ?? 0), ordinal >= previous,
                  let at = entry["received_at"]?.stringValue, Self.time(at) else { throw CompanionRelayError.invalid }
            previous = ordinal
            return CompanionListedRequest(requestID: id, ordinal: ordinal, receivedAt: at)
        }
        let next: Int64?
        if value["next"] == .null { next = nil }
        else {
            guard let n = CompanionWire.unsigned(value["next"]), !requests.isEmpty, n == previous else { throw CompanionRelayError.invalid }; next = n
        }
        return CompanionRelayReply(status: 200, value: CompanionRequestPage(requests: requests, next: next), receivedBytes: reply.receivedBytes)
    }
    /// Never delete a request before its durable outcome, discard check, or confirmed-lost proof (§9.3).
    public func deleteRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<Data> {
        guard CompanionWire.isID(deviceID), CompanionWire.isID(requestID) else { throw CompanionRelayError.invalid }
        return try await call("/v0/requests/" + deviceID + "/" + requestID, method: "DELETE", downloadLimit: downloadLimit)
    }
    /// Relay status alone never revokes local state. Reconciliation verifies signed self-revocation separately.
    public func deleteDevice(deviceID: String, downloadLimit: Int) async throws -> CompanionRelayReply<Data> {
        guard CompanionWire.isID(deviceID) else { throw CompanionRelayError.invalid }
        return try await call("/v0/devices/" + deviceID, method: "DELETE", downloadLimit: downloadLimit)
    }
    private func mailboxJSON(_ bytes: Data?) throws -> JSONValue {
        guard let bytes else { throw CompanionRelayError.invalid }
        do {
            let value = try CompanionWire.parse(bytes, limit: 16384)
            guard value.objectValue != nil else { throw CompanionRelayError.invalid }; return value
        } catch { throw CompanionRelayError.invalid }
    }
    private func mailboxTime(_ value: JSONValue?) throws -> String? {
        if value == .null { return nil }
        guard let at = value?.stringValue, Self.time(at) else { throw CompanionRelayError.invalid }; return at
    }
}
