import Foundation
import SpravaKit

public enum CompanionDecisionOutcome: String, Sendable { case applied, conflict, rejected, unknown }
public enum CompanionDecisionRejection: String, Sendable {
    case invalid, staleSequence = "stale-seq", notShown = "not-shown", notInBinder = "not-in-binder", futureVersion = "future-version"
}
/// Full bytes supplied by a higher adapter; this journal neither constructs nor executes binder/capture effects.
public enum CompanionDecisionEffect: Sendable {
    case none
    case rejection(CompanionDecisionRejection)
    case operation(binderID: String, id: String, bytes: Data)
    case capture(id: String, bytes: Data)
    case conflict(bytes: Data)
}
public struct CompanionDecisionPlan: Sendable {
    public let outcome: CompanionDecisionOutcome
    public let effect: CompanionDecisionEffect
    public init(outcome: CompanionDecisionOutcome, effect: CompanionDecisionEffect) { self.outcome = outcome; self.effect = effect }
}
public struct CompanionDecisionRecord: Sendable {
    public let request: CompanionAuthenticatedRequest
    public let plan: CompanionDecisionPlan
    public let createdAt: String
    let bytes: Data // Exact compare-and-commit token; never log or send this plaintext record.
}
public struct CompanionOutcomeTombstone: Sendable {
    public let deviceID: String
    public let requestID: String
    public let sequence: Int64
    public let outcome: CompanionDecisionOutcome
    public let decidedAt: String
}
public enum CompanionDecisionLookup: Sendable {
    case none, deciding(CompanionDecisionRecord), decided(CompanionOutcomeTombstone)
}
public enum CompanionDecisionError: Error, Equatable { case invalid, busy, dailyCap, unavailable }

extension CompanionProfile {
    func decisionBytes(_ request: CompanionAuthenticatedRequest, plan: CompanionDecisionPlan, at: String) throws -> Data {
        let fields: [(key: String, value: JSONValue)] = [
            ("device", .string(request.deviceID)), ("request", .string(request.requestID)),
            ("seq", .number(JSONNumber(text: String(request.sequence)))), ("epoch", .number(JSONNumber(text: String(request.epoch)))),
            ("action", actionJSON(request.action)), ("outcome", .string(plan.outcome.rawValue)),
            ("effect", try effectJSON(plan, request: request)), ("at", .string(at))]
        let bytes = Data(JSONWriter.compact(.object(JSONObject(fields))).utf8)
        guard bytes.count <= 524288 else { throw CompanionDecisionError.invalid }
        return bytes
    }
    func decodeDecision(_ bytes: Data, device: String, request id: String) throws -> CompanionDecisionRecord {
        let v = try CompanionWire.parse(bytes, limit: 524288)
        guard v["device"]?.stringValue == device, v["request"]?.stringValue == id, CompanionWire.isID(device), CompanionWire.isID(id),
              let seq = CompanionWire.unsigned(v["seq"]), seq >= 1, let e = CompanionWire.unsigned(v["epoch"]), e >= 1,
              let at = v["at"]?.stringValue, CompanionOwnerRelay.time(at), let outcome = v["outcome"]?.stringValue,
              let o = CompanionDecisionOutcome(rawValue: outcome) else { throw CompanionDecisionError.invalid }
        let action: CompanionRequestedAction?
        if v["action"] == .null { action = nil }
        else {
            guard let value = v["action"], let decoded = requestedAction(value, length: 1024) else { throw CompanionDecisionError.invalid }
            action = decoded
        }
        let request = CompanionAuthenticatedRequest(deviceID: device, requestID: id, epoch: e, sequence: seq, action: action)
        let effect = try decodeEffect(v["effect"]), plan = CompanionDecisionPlan(outcome: o, effect: effect)
        _ = try effectJSON(plan, request: request)
        return CompanionDecisionRecord(request: request, plan: plan, createdAt: at, bytes: bytes)
    }
    private func actionJSON(_ a: CompanionRequestedAction?) -> JSONValue {
        guard let a else { return .null }
        return .object(JSONObject([("type", .string(a.kind.rawValue)), ("made_at", .string(a.madeAt)),
            ("binder", a.binderID.map(JSONValue.string) ?? .null), ("item", a.itemID ?? .null),
            ("seen_version", a.seenVersion.map { .number(JSONNumber(text: String($0))) } ?? .null),
            ("date", a.date.map(JSONValue.string) ?? .null), ("text", a.text.map(JSONValue.string) ?? .null), ("pad", .string(""))]))
    }
    private func effectJSON(_ p: CompanionDecisionPlan, request: CompanionAuthenticatedRequest) throws -> JSONValue {
        var fields: [(key: String, value: JSONValue)] = []
        func payload(_ bytes: Data) throws -> JSONValue {
            guard bytes.count <= 262144, let o = try CompanionWire.parse(bytes, limit: 262144).objectValue else { throw CompanionDecisionError.invalid }
            return .object(o)
        }
        func uuid(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString.lowercased() == id }
        switch p.effect {
        case .none:
            guard p.outcome == .unknown || (p.outcome == .applied && request.action?.kind != .note && request.action != nil) else { throw CompanionDecisionError.invalid }
            fields = [("kind", .string("none"))]
        case .rejection(let reason):
            guard p.outcome == .rejected else { throw CompanionDecisionError.invalid }
            fields = [("kind", .string("rejection")), ("reason", .string(reason.rawValue))]
        case .operation(let binder, let id, let bytes):
            guard p.outcome == .applied, let action = request.action, action.kind != .note, binder == action.binderID,
                  CompanionWire.isID(binder), uuid(id) else { throw CompanionDecisionError.invalid }
            let v = try payload(bytes)
            guard v["id"] == .string(id), v["actor"]?["kind"] == .string("user"),
                  v["note"] == .string("companion:\(request.deviceID)/\(request.requestID)") else { throw CompanionDecisionError.invalid }
            fields = [("kind", .string("operation")), ("binder", .string(binder)), ("id", .string(id)), ("bytes", .string(CompanionWire.base64(bytes)))]
        case .capture(let id, let bytes):
            guard p.outcome == .applied, request.action?.kind == .note, uuid(id) else { throw CompanionDecisionError.invalid }
            let v = try payload(bytes), tag = v["extensions"]?["sprava"]?["companion"]
            guard v["id"] == .string(id), let text = v["text"]?.stringValue, let original = request.action?.text,
                  text.utf8.elementsEqual(original.utf8),
                  tag?["device_id"] == .string(request.deviceID), tag?["request_id"] == .string(request.requestID) else { throw CompanionDecisionError.invalid }
            fields = [("kind", .string("capture")), ("id", .string(id)), ("bytes", .string(CompanionWire.base64(bytes)))]
        case .conflict(let bytes):
            guard p.outcome == .conflict, request.action != nil else { throw CompanionDecisionError.invalid }
            _ = try payload(bytes)
            fields = [("kind", .string("conflict")), ("bytes", .string(CompanionWire.base64(bytes)))]
        }
        if request.action == nil {
            guard p.outcome == .rejected || p.outcome == .unknown else { throw CompanionDecisionError.invalid }
        }
        return .object(JSONObject(fields))
    }
    private func decodeEffect(_ v: JSONValue?) throws -> CompanionDecisionEffect {
        guard let kind = v?["kind"]?.stringValue else { throw CompanionDecisionError.invalid }
        if kind == "none" { return .none }
        if kind == "rejection", let raw = v?["reason"]?.stringValue, let reason = CompanionDecisionRejection(rawValue: raw) { return .rejection(reason) }
        guard let text = v?["bytes"]?.stringValue else { throw CompanionDecisionError.invalid }
        let bytes = try CompanionWire.decode(text)
        if kind == "conflict" { return .conflict(bytes: bytes) }
        guard let id = v?["id"]?.stringValue else { throw CompanionDecisionError.invalid }
        if kind == "capture" { return .capture(id: id, bytes: bytes) }
        if kind == "operation", let binder = v?["binder"]?.stringValue { return .operation(binderID: binder, id: id, bytes: bytes) }
        throw CompanionDecisionError.invalid
    }
}
