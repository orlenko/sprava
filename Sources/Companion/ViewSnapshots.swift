import CryptoKit
import Foundation
import SpravaKit

public struct CompanionViewPublication: Sendable {
    public let binderID: String
    public let version: Int64
    public let epoch: Int64
    public let bytes: Data
    public var name: String { "views/\(binderID)/\(version)" }
}
public struct CompanionPreparedView: Sendable {
    public let publication: CompanionViewPublication
    public let notesOmitted: Bool
    public let issues: [CompanionProjectionIssue]
}

extension CompanionProfile {
    /// companion-v0 §9.7: caller holds the binder's write lock across reading and this atomic snapshot.
    /// Versions, whole-item hashes and exact sealed bytes commit together; plaintext is never persisted.
    public func prepareView(binderID: String, reading: CompanionViewReading) throws -> CompanionPreparedView {
        try prepareView(binderID: binderID, reading: reading, beforeCommit: {})
    }
    func prepareView(binderID: String, reading: CompanionViewReading, beforeCommit: () throws -> Void) throws -> CompanionPreparedView {
        guard CompanionWire.isID(binderID) else { throw CompanionPublicationError.invalid }
        return try store.write { t in
            guard let head = try viewBinder(binderID, t), try viewAllowed(head, t),
                  head.reserved < JSONNumber.maxSafeInteger else { throw CompanionPublicationError.unavailable }
            let history = try viewHistory(binderID, reserved: head.reserved, t)
            let version = head.reserved + 1
            let projection = try CompanionViewProjection.project(binderID: binderID, version: version, reading: reading, previous: history)
            guard let keyBytes = try secrets.read(account: binderKeyAccount(binderID, epoch: head.epoch)), keyBytes.count == 32,
                  let owner = try CompanionOwnerVault(backend: secrets).load(relay) else { throw CompanionCredentialError.unavailable }
            let name = "views/\(binderID)/\(version)"
            let bytes = try CompanionSealedObject.seal(name: name, epoch: head.epoch, key: SymmetricKey(data: keyBytes),
                plaintext: projection.plaintext, signer: owner.signingKey)
            // A superseded pending upload cannot resume, but the last uploaded version still backs the index.
            try t.execute("DELETE FROM phone_views WHERE binder = ? AND state = 'uploading'", .text(binderID))
            try t.execute("INSERT INTO phone_views VALUES (?, ?, ?, ?, 'uploading', ?)", .text(binderID), .integer(version),
                          .integer(head.epoch), .text(Self.phoneName(reading.name)), .blob(bytes))
            try t.execute("UPDATE phone_binders SET highest_reserved = ? WHERE binder = ?", .integer(version), .text(binderID))
            try t.execute("DELETE FROM phone_item_snapshots WHERE binder = ?", .text(binderID))
            for item in projection.history.items {
                try t.execute("INSERT INTO phone_item_snapshots VALUES (?, ?, ?, ?)", .text(binderID),
                              .blob(Data(JSONWriter.compact(item.id).utf8)), .text(item.hash), .integer(item.changedIn))
            }
            try beforeCommit()
            return CompanionPreparedView(publication: CompanionViewPublication(binderID: binderID, version: version,
                epoch: head.epoch, bytes: bytes), notesOmitted: projection.notesOmitted, issues: projection.issues)
        }
    }
    /// Caller holds this binder's upload lock through pending/read, PUT, and completion or retirement.
    /// Restart retries only the newest snapshot and always with the previously recorded ciphertext.
    public func pendingView(binderID: String) throws -> CompanionViewPublication? {
        guard CompanionWire.isID(binderID) else { throw CompanionPublicationError.invalid }
        return try store.read { t in
            guard let binder = try viewBinder(binderID, t), try viewAllowed(binder, t),
                  let row = try viewRecord(binderID, version: binder.reserved, t), row.state == "uploading",
                  row.value.epoch == binder.epoch else { return nil }
            return row.value
        }
    }
    /// A removed binder or stale upload cannot make a version eligible for a new index.
    @discardableResult
    public func completeView(_ publication: CompanionViewPublication) throws -> Bool {
        try store.write { t in
            guard let binder = try viewBinder(publication.binderID, t), try viewAllowed(binder, t),
                  publication.version == binder.reserved, publication.epoch == binder.epoch,
                  let row = try viewRecord(publication.binderID, version: publication.version, t) else { return false }
            try matchView(publication, row.value)
            if row.state == "uploaded" { return true }
            try t.execute("UPDATE phone_views SET state = 'uploaded' WHERE binder = ? AND version = ?",
                          .text(publication.binderID), .integer(publication.version))
            return true
        }
    }
    /// A 409/410 or a failed upload drops its pending bytes but never rewinds hashes or reserved versions.
    public func supersedeView(_ publication: CompanionViewPublication) throws {
        try store.write { t in
            guard let row = try viewRecord(publication.binderID, version: publication.version, t) else { return }
            try matchView(publication, row.value)
            if row.state == "uploading" {
                try t.execute("DELETE FROM phone_views WHERE binder = ? AND version = ?", .text(publication.binderID), .integer(publication.version))
            }
        }
    }
    private struct ViewBinder { let state: String; let reserved: Int64; let epoch: Int64 }
    private func viewBinder(_ id: String, _ t: Transaction) throws -> ViewBinder? {
        let rows = try t.rows("SELECT state, highest_reserved, highest_indexed, key_epoch FROM phone_binders WHERE binder = ?", .text(id))
        guard let r = rows.first else { return nil }
        guard r.count == 4, let state = r[0].text, ["preparing", "shown", "removed"].contains(state),
              let reserved = r[1].integer, let indexed = r[2].integer, indexed >= 0, reserved >= indexed,
              reserved <= JSONNumber.maxSafeInteger, let e = r[3].integer, e >= 1, e <= JSONNumber.maxSafeInteger else {
            throw CompanionPublicationError.invalid
        }
        return ViewBinder(state: state, reserved: reserved, epoch: e)
    }
    private func viewAllowed(_ binder: ViewBinder, _ t: Transaction) throws -> Bool {
        guard binder.state == "shown", try epoch(t) == binder.epoch, try claimState(t) == .claimed else { return false }
        return try t.rows("SELECT 1 FROM recipients r JOIN devices d ON d.device = r.device " +
                          "WHERE r.epoch = ? AND d.state = 'revoked' LIMIT 1", .integer(binder.epoch)).isEmpty
    }
    private func viewHistory(_ id: String, reserved: Int64, _ t: Transaction) throws -> CompanionViewHistory? {
        let rows = try t.rows("SELECT id, hash, changed_in FROM phone_item_snapshots WHERE binder = ? ORDER BY id LIMIT 200001", .text(id))
        guard rows.count <= 200000, reserved > 0 || rows.isEmpty else { throw CompanionPublicationError.invalid }
        let items = try rows.map { r -> CompanionItemSnapshot in
            guard r.count == 3, let bytes = r[0].blob, bytes.count <= 802, let hash = r[1].text,
                  hash.utf8.count == 71, hash.hasPrefix("sha256:"), hash.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let changed = r[2].integer, changed >= 1, changed <= reserved else { throw CompanionPublicationError.invalid }
            let rawID = try CompanionWire.parse(bytes, limit: 802)
            guard ProjectionID.parse(rawID) != nil else { throw CompanionPublicationError.invalid }
            return CompanionItemSnapshot(id: rawID, hash: hash, changedIn: changed)
        }
        return reserved == 0 ? nil : CompanionViewHistory(binderID: id, version: reserved, items: items)
    }
    private func viewRecord(_ id: String, version: Int64, _ t: Transaction) throws -> (value: CompanionViewPublication, state: String)? {
        let rows = try t.rows("SELECT epoch, state, bytes FROM phone_views WHERE binder = ? AND version = ?", .text(id), .integer(version))
        guard let r = rows.first else { return nil }
        guard CompanionWire.isID(id), version >= 1, version <= JSONNumber.maxSafeInteger, r.count == 3,
              let e = r[0].integer, e >= 1, e <= JSONNumber.maxSafeInteger, let state = r[1].text,
              ["uploading", "uploaded"].contains(state), let bytes = r[2].blob, !bytes.isEmpty, bytes.count <= 1048576 else {
            throw CompanionPublicationError.invalid
        }
        return (CompanionViewPublication(binderID: id, version: version, epoch: e, bytes: bytes), state)
    }
    private func matchView(_ a: CompanionViewPublication, _ b: CompanionViewPublication) throws {
        guard a.binderID == b.binderID, a.version == b.version, a.epoch == b.epoch, a.bytes == b.bytes else { throw CompanionPublicationError.invalid }
    }
}
