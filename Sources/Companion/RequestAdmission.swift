import CryptoKit
import Foundation
import SpravaKit

public struct CompanionRequestedAction: Sendable {
    public enum Kind: String, Sendable { case done, drop, followUp = "follow_up", arrived, postpone, note }
    public let kind: Kind
    public let madeAt: String
    public let binderID: String?
    public let itemID: JSONValue?
    public let seenVersion: Int64?
    public let date: String?
    public let text: String?
}
public struct CompanionAuthenticatedRequest: Sendable {
    public let deviceID: String
    public let requestID: String
    public let epoch: Int64
    public let sequence: Int64
    /// Nil means an authenticated invalid action: decide it as rejected in sequence order, never discard it.
    public let action: CompanionRequestedAction?
}
public enum CompanionRequestAdmission: Sendable {
    public enum Discard: String, Sendable { case badID = "bad-id", notActive = "not-active", tooLarge = "too-large", unreadable, noSequence = "no-seq" }
    case discarded(Discard)
    case authenticated(CompanionAuthenticatedRequest)
}

extension CompanionProfile {
    /// companion-v0 §9.3 checks 1, 3, 5–7. No mutation, effects, diagnostics, tombstones or outcomes.
    /// Drain holds the device decision lock, checks duplicates first (check 2), and supplies a whole body.
    /// A cut-short download is a job failure before this call. Local state/key errors also throw, never discard.
    public func admitRequest(deviceID: String, requestID: String, bytes: Data) throws -> CompanionRequestAdmission {
        guard CompanionWire.isID(deviceID), CompanionWire.isID(requestID) else { return .discarded(.badID) }
        return try store.read { t in
            guard let device = try record(deviceID, t), device.state == .active else { return .discarded(.notActive) }
            guard bytes.count <= 65536 else { return .discarded(.tooLarge) }
            guard let current = try epoch(t), let key = try secrets.read(account: deviceAccount(deviceID)) else {
                throw CompanionCredentialError.unavailable
            }
            guard key.count == 32 else { throw CompanionCredentialError.invalid }
            let plaintext: Data, e: Int64
            do {
                let envelope = try CompanionWire.parse(bytes, limit: 65536)
                guard let number = CompanionWire.unsigned(envelope["e"]), number >= 1, number <= current else { return .discarded(.unreadable) }
                e = number
                plaintext = try CompanionSealedObject.openPlaintext(name: "requests/\(deviceID)/\(requestID)", epoch: e,
                    key: SymmetricKey(data: key), bytes: bytes)
            } catch { return .discarded(.unreadable) }
            let payload: JSONValue, seq: Int64
            do {
                payload = try CompanionWire.parse(plaintext, limit: 48128)
                guard payload.objectValue != nil, let value = CompanionWire.unsigned(payload["seq"]), value >= 1 else {
                    return .discarded(.noSequence)
                }
                seq = value
            } catch { return .discarded(.noSequence) }
            let action = requestedAction(payload, length: plaintext.count)
            return .authenticated(CompanionAuthenticatedRequest(deviceID: deviceID, requestID: requestID, epoch: e, sequence: seq, action: action))
        }
    }
    func requestedAction(_ payload: JSONValue, length: Int) -> CompanionRequestedAction? {
        guard length >= 1024, length % 1024 == 0, let pad = payload["pad"]?.stringValue, pad.utf8.allSatisfy({ $0 == 32 }),
              let rawKind = payload["type"]?.stringValue, let kind = CompanionRequestedAction.Kind(rawValue: rawKind),
              let made = payload["made_at"]?.stringValue, CompanionOwnerRelay.time(made) else { return nil }
        func absent(_ name: String) -> Bool { payload[name] == nil || payload[name] == .null }
        var binder: String?
        if !absent("binder") {
            guard let id = payload["binder"]?.stringValue, CompanionWire.isID(id) else { return nil }
            binder = id
        }
        if kind == .note {
            guard absent("item"), absent("seen_version"), absent("date"), let text = payload["text"]?.stringValue,
                  !text.isEmpty, text.unicodeScalars.prefix(10001).count <= 10000,
                  JSONWriter.compact(.string(text)).utf8.count - 2 <= 40000,
                  text.unicodeScalars.allSatisfy({ $0.value >= 32 || $0.value == 9 || $0.value == 10 }) else { return nil }
            return CompanionRequestedAction(kind: kind, madeAt: made, binderID: binder, itemID: nil, seenVersion: nil, date: nil, text: text)
        }
        guard binder != nil, ProjectionID.parse(payload["item"]) != nil,
              let version = CompanionWire.unsigned(payload["seen_version"]), version >= 1, absent("text") else { return nil }
        var date: String?
        if kind == .followUp || kind == .postpone {
            guard let day = payload["date"]?.stringValue, CalendarDate.strict(day) != nil else { return nil }
            date = day
        } else if !absent("date") { return nil }
        return CompanionRequestedAction(kind: kind, madeAt: made, binderID: binder, itemID: payload["item"], seenVersion: version, date: date, text: nil)
    }
}
