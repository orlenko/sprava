import CryptoKit
import Foundation
import SpravaKit

/// Stable 128-bit identity supplied by a higher adapter; never manufacture this from a binder's name or path.
public struct CompanionLocalBinderIdentity: Sendable {
    let bytes: Data
    public init(bytes: Data) throws {
        guard bytes.count == 16 else { throw CompanionPublicationError.invalid }
        self.bytes = bytes
    }
}
public struct CompanionBinderSharing: Sendable {
    public enum State: String, Sendable { case preparing, shown, removed }
    public let id: String
    public let state: State
    public let keyEpoch: Int64
}

extension CompanionProfile {
    /// companion-v0 §8.4: reserve a new phone id before installing its immutable key. Sharing starts off.
    public func showBinder(_ identity: CompanionLocalBinderIdentity) throws -> CompanionBinderSharing {
        let reserved = try store.write { t in
            guard try claimState(t) == .claimed, let e = try epoch(t),
                  try t.rows("SELECT 1 FROM recipients r JOIN devices d ON d.device = r.device " +
                             "WHERE r.epoch = ? AND d.state = 'revoked' LIMIT 1", .integer(e)).isEmpty else {
                throw CompanionPublicationError.unavailable
            }
            if let existing = try sharing(identity, t) { return existing }
            let count = try t.rows("SELECT COUNT(*) FROM phone_binders WHERE state != 'removed'").first?.first?.integer
            guard let count, count >= 0 else { throw CompanionPublicationError.invalid }
            guard count < 100 else { throw CompanionPublicationError.tooManyBinders }
            let id = CompanionWire.base64(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
            try t.execute("INSERT INTO phone_binders (binder, state, local_identity, key_epoch) VALUES (?, 'preparing', ?, ?)",
                          .text(id), .blob(identity.bytes), .integer(e))
            return CompanionBinderSharing(id: id, state: .preparing, keyEpoch: e)
        }
        return try finishShowingBinder(id: reserved.id)
    }
    /// Recover a reserved key after a failed write/commit. A shown binder's missing key is never regenerated.
    public func finishShowingBinder(id: String) throws -> CompanionBinderSharing {
        try finishShowingBinder(id: id, beforeCommit: {})
    }
    func finishShowingBinder(id: String, beforeCommit: () throws -> Void) throws -> CompanionBinderSharing {
        guard CompanionWire.isID(id) else { throw CompanionPublicationError.invalid }
        return try store.write { t in
            guard try claimState(t) == .claimed, let e = try epoch(t), let r = try sharing(id, t),
                  r.state == .preparing || r.state == .shown, r.keyEpoch == e,
                  try t.rows("SELECT 1 FROM recipients r JOIN devices d ON d.device = r.device " +
                             "WHERE r.epoch = ? AND d.state = 'revoked' LIMIT 1", .integer(e)).isEmpty else {
                throw CompanionPublicationError.unavailable
            }
            let account = binderKeyAccount(id, epoch: e)
            if r.state == .preparing, try secrets.read(account: account) == nil {
                _ = try secrets.insert(account: account, bytes: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
            }
            guard let key = try secrets.read(account: account) else { throw CompanionCredentialError.unavailable }
            guard key.count == 32 else { throw CompanionCredentialError.invalid }
            try t.execute("UPDATE phone_binders SET state = 'shown' WHERE binder = ?", .text(id))
            try beforeCommit()
            return CompanionBinderSharing(id: id, state: .shown, keyEpoch: e)
        }
    }
    public func binderSharing(_ identity: CompanionLocalBinderIdentity) throws -> CompanionBinderSharing? {
        try store.read { t in
            guard try epoch(t) != nil else { return nil }
            return try sharing(identity, t)
        }
    }
    /// Turn off even during claim suspension. Keep the old id and counters for safe cleanup behind a new index.
    /// Old keys remain until that cleanup finishes; neither a snapshot nor a new index includes a removed id.
    public func hideBinder(_ identity: CompanionLocalBinderIdentity) throws {
        try store.write { t in
            guard try epoch(t) != nil else { throw CompanionPublicationError.invalid }
            try t.execute("UPDATE phone_binders SET state = 'removed' WHERE local_identity = ? AND state != 'removed'", .blob(identity.bytes))
        }
    }
    private func sharing(_ identity: CompanionLocalBinderIdentity, _ t: Transaction) throws -> CompanionBinderSharing? {
        let rows = try t.rows("SELECT binder, state, key_epoch FROM phone_binders WHERE local_identity = ? AND state != 'removed' LIMIT 2",
                              .blob(identity.bytes))
        guard rows.count <= 1 else { throw CompanionPublicationError.invalid }
        return try rows.first.map(decodeSharing)
    }
    private func sharing(_ id: String, _ t: Transaction) throws -> CompanionBinderSharing? {
        try t.rows("SELECT binder, state, key_epoch FROM phone_binders WHERE binder = ?", .text(id)).first.map(decodeSharing)
    }
    private func decodeSharing(_ row: [StateValue]) throws -> CompanionBinderSharing {
        guard row.count == 3, let id = row[0].text, CompanionWire.isID(id), let raw = row[1].text,
              let state = CompanionBinderSharing.State(rawValue: raw), let e = row[2].integer,
              e >= 1, e <= JSONNumber.maxSafeInteger else { throw CompanionPublicationError.invalid }
        return CompanionBinderSharing(id: id, state: state, keyEpoch: e)
    }
}
