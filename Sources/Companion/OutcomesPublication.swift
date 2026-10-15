import CryptoKit
import Foundation
import SpravaKit

public struct CompanionOutcomesPublication: Sendable {
    public let deviceID: String
    public let revision: Int64
    public let changes: Int64
    public let bytes: Data
    public var name: String { "devices/\(deviceID)/outcomes/\(revision)" }
}

extension CompanionProfile {
    /// companion-v0 §9.9: caller holds the device decision lock; only committed tombstones enter this payload.
    /// Reserve exact signed ciphertext before upload. Retry pending bytes before building from newer decisions.
    public func prepareOutcomes(deviceID: String, generatedAt: String) throws -> CompanionOutcomesPublication? {
        try prepareOutcomes(deviceID: deviceID, generatedAt: generatedAt, beforeCommit: {})
    }
    func prepareOutcomes(deviceID: String, generatedAt: String, beforeCommit: () throws -> Void) throws -> CompanionOutcomesPublication? {
        guard CompanionWire.isID(deviceID), CompanionOwnerRelay.time(generatedAt), let now = Timestamp.parse(generatedAt) else {
            throw CompanionPublicationError.invalid
        }
        return try store.write { t in
            guard try record(deviceID, t)?.state == .active else { return nil }
            guard try claimState(t) == .claimed else { throw CompanionPublicationError.unavailable }
            let marks = try outcomesMarks(deviceID, t)
            if let head = try outcomesHead(deviceID, marks: marks, t), head.state == "uploading" { return head.value }
            if marks.changes == marks.built { return nil }
            guard marks.reserved < JSONNumber.maxSafeInteger else { throw CompanionPublicationError.unavailable }
            let revision = marks.reserved + 1, cutoff = now.addingTimeInterval(-30 * 86400).ISO8601Format()
            let rows = try t.rows("SELECT request, seq, outcome, decided_at FROM outcome_tombstones WHERE device = ? AND decided_at >= ? " +
                "ORDER BY decided_at DESC, seq DESC, request LIMIT 2000", .text(deviceID), .text(cutoff))
            let entries = try rows.map { row -> JSONValue in
                guard row.count == 4, let r = row[0].text, CompanionWire.isID(r), let seq = row[1].integer,
                      seq >= 1, seq <= JSONNumber.maxSafeInteger, let outcome = row[2].text, CompanionDecisionOutcome(rawValue: outcome) != nil,
                      let at = row[3].text, CompanionOwnerRelay.time(at) else { throw CompanionPublicationError.invalid }
                return .object(JSONObject([("request_id", .string(r)), ("seq", .number(JSONNumber(text: String(seq)))),
                    ("outcome", .string(outcome)), ("decided_at", .string(at))]))
            }
            var fields: [(key: String, value: JSONValue)] = [("device_id", .string(deviceID)), ("revision", .number(JSONNumber(text: String(revision)))),
                ("generated_at", .string(generatedAt)), ("outcomes", .array(entries)), ("pad", .string(""))]
            let length = JSONWriter.compact(.object(JSONObject(fields))).utf8.count, target = 512 + 128 * entries.count
            guard length <= target else { throw CompanionPublicationError.invalid }
            fields[fields.count - 1] = ("pad", .string(String(repeating: " ", count: target - length)))
            let plaintext = Data(JSONWriter.compact(.object(JSONObject(fields))).utf8)
            guard let kd = try secrets.read(account: deviceAccount(deviceID)), kd.count == 32,
                  let owner = try CompanionOwnerVault(backend: secrets).load(relay) else { throw CompanionCredentialError.unavailable }
            let bytes = try CompanionSealedObject.seal(name: "devices/\(deviceID)/outcomes/\(revision)", epoch: 0,
                key: SymmetricKey(data: kd), plaintext: plaintext, signer: owner.signingKey)
            try t.execute("INSERT OR REPLACE INTO outcomes_upload VALUES (?, ?, ?, 'uploading', ?)",
                          .text(deviceID), .integer(revision), .integer(marks.changes), .blob(bytes))
            try t.execute("UPDATE decision_state SET outcomes_reserved = ? WHERE device = ?", .integer(revision), .text(deviceID))
            try beforeCommit()
            return CompanionOutcomesPublication(deviceID: deviceID, revision: revision, changes: marks.changes, bytes: bytes)
        }
    }
    public func pendingOutcomes(deviceID: String) throws -> CompanionOutcomesPublication? {
        guard CompanionWire.isID(deviceID) else { throw CompanionPublicationError.invalid }
        return try store.read { t in
            guard try record(deviceID, t)?.state == .active, try claimState(t) == .claimed else { return nil }
            let marks = try outcomesMarks(deviceID, t)
            guard let head = try outcomesHead(deviceID, marks: marks, t), head.state == "uploading" else { return nil }
            return head.value
        }
    }
    /// Caller re-takes the decision lock after PUT. A concurrent decision remains dirty for the next revision.
    @discardableResult
    public func completeOutcomes(_ publication: CompanionOutcomesPublication) throws -> Bool {
        try store.write { t in
            guard try record(publication.deviceID, t)?.state == .active else { return false }
            let marks = try outcomesMarks(publication.deviceID, t)
            guard let head = try outcomesHead(publication.deviceID, marks: marks, t) else { throw CompanionPublicationError.invalid }
            if publication.revision < head.value.revision { return false }
            try matchOutcomes(publication, head.value)
            if head.state == "superseded" { return false }
            if head.state == "published" { return true }
            try t.execute("UPDATE outcomes_upload SET state = 'published' WHERE device = ?", .text(publication.deviceID))
            try t.execute("UPDATE decision_state SET outcomes_published = ?, outcomes_built = ? WHERE device = ?",
                          .integer(publication.revision), .integer(publication.changes), .text(publication.deviceID))
            return true
        }
    }
    /// Retire a 409/410 name, retaining its reserved revision and dirty counter. Never rebuild under that name.
    public func supersedeOutcomes(_ publication: CompanionOutcomesPublication) throws {
        try store.write { t in
            let marks = try outcomesMarks(publication.deviceID, t)
            guard let head = try outcomesHead(publication.deviceID, marks: marks, t) else { throw CompanionPublicationError.invalid }
            if publication.revision < head.value.revision { return }
            try matchOutcomes(publication, head.value)
            try t.execute("UPDATE outcomes_upload SET state = 'superseded' WHERE device = ? AND state = 'uploading'", .text(publication.deviceID))
        }
    }
    private struct OutcomeMarks { let changes: Int64; let built: Int64; let reserved: Int64; let published: Int64 }
    private func outcomesMarks(_ d: String, _ t: Transaction) throws -> OutcomeMarks {
        let rows = try t.rows("SELECT outcomes_generation, outcomes_built, outcomes_reserved, outcomes_published FROM decision_state WHERE device = ?", .text(d))
        guard let row = rows.first else { return OutcomeMarks(changes: 0, built: 0, reserved: 0, published: 0) }
        guard row.count == 4, let changes = row[0].integer, let built = row[1].integer, let reserved = row[2].integer, let published = row[3].integer,
              built >= 0, built <= changes, changes <= JSONNumber.maxSafeInteger, published >= 0, published <= reserved,
              reserved <= JSONNumber.maxSafeInteger else { throw CompanionPublicationError.invalid }
        return OutcomeMarks(changes: changes, built: built, reserved: reserved, published: published)
    }
    private func outcomesHead(_ d: String, marks: OutcomeMarks, _ t: Transaction) throws -> (value: CompanionOutcomesPublication, state: String)? {
        let rows = try t.rows("SELECT revision, changes, state, bytes FROM outcomes_upload WHERE device = ?", .text(d))
        guard let row = rows.first else {
            guard marks.reserved == 0 else { throw CompanionPublicationError.invalid }; return nil
        }
        guard row.count == 4, let r = row[0].integer, r >= 1, r == marks.reserved, let changes = row[1].integer,
              changes >= marks.built, changes <= marks.changes, let state = row[2].text, ["uploading", "published", "superseded"].contains(state),
              (state == "published") == (r == marks.published), let bytes = row[3].blob, !bytes.isEmpty, bytes.count <= 524288 else {
            throw CompanionPublicationError.invalid
        }
        return (CompanionOutcomesPublication(deviceID: d, revision: r, changes: changes, bytes: bytes), state)
    }
    private func matchOutcomes(_ a: CompanionOutcomesPublication, _ b: CompanionOutcomesPublication) throws {
        guard a.deviceID == b.deviceID, a.revision == b.revision, a.changes == b.changes, a.bytes == b.bytes else { throw CompanionPublicationError.invalid }
    }
}
