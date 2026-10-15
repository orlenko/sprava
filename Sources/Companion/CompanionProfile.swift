import CryptoKit
import Foundation
import SpravaKit

public struct CompanionAccountEpoch: Sendable {
    public let number: Int64
    public let key: SymmetricKey
}

/// companion-v0 §§4.1, 9.1: account secrets in Keychain, committed epoch metadata in this target's SQLite.
/// Explicit paths and backends only. This initial-state API performs no rotation, publishing or network calls.
public final class CompanionProfile: Sendable {
    let store: StateStore
    let relay: CompanionRelayIdentity
    let secrets: any CompanionCredentialStorage
    static let schema = StateStore.Schema(version: 13, statements: [
        "CREATE TABLE profile (slot INTEGER PRIMARY KEY CHECK (slot = 1), origin TEXT NOT NULL, " +
        "instance TEXT NOT NULL, epoch INTEGER NOT NULL CHECK (epoch BETWEEN 1 AND 9007199254740991), " +
        "index_reserved INTEGER NOT NULL DEFAULT 0, index_published INTEGER NOT NULL DEFAULT 0, " +
        "claim_state TEXT NOT NULL DEFAULT 'pending' CHECK (claim_state IN ('pending','claimed','checking-refusal','needs-reset','instance-changed')), web_origin TEXT)",
        "CREATE TABLE devices (device TEXT PRIMARY KEY, state TEXT NOT NULL CHECK (state IN ('pairing','active','revoked','abandoned')), " +
        "key_ready INTEGER NOT NULL CHECK (key_ready IN (0,1)), creation_attempted INTEGER NOT NULL CHECK (creation_attempted IN (0,1)), " +
        "cleanup_pending INTEGER NOT NULL CHECK (cleanup_pending IN (0,1)), " +
        "highest_seq INTEGER NOT NULL DEFAULT 0 CHECK (highest_seq BETWEEN 0 AND 9007199254740991), " +
        "local_deadline TEXT, next_poll TEXT) WITHOUT ROWID",
        "CREATE TABLE pairings (device TEXT PRIMARY KEY REFERENCES devices(device), pairing TEXT NOT NULL UNIQUE, " +
        "expires TEXT NOT NULL, public_b BLOB, hello BLOB, label TEXT, approval TEXT, wrapped_key BLOB, device_keys BLOB, " +
        "key_epoch INTEGER, paired_at TEXT, acknowledged INTEGER NOT NULL DEFAULT 0, " +
        "ephemeral_cleanup INTEGER NOT NULL DEFAULT 0, delivery_next TEXT, delivery_attempts INTEGER NOT NULL DEFAULT 0, " +
        "keys_uploaded INTEGER NOT NULL DEFAULT 0, wrapped_uploaded INTEGER NOT NULL DEFAULT 0, delivery_blocked INTEGER) WITHOUT ROWID",
        "CREATE TABLE recipients (epoch INTEGER NOT NULL, device TEXT NOT NULL REFERENCES devices(device), " +
        "PRIMARY KEY(epoch, device)) WITHOUT ROWID",
        "CREATE TABLE phone_binders (binder TEXT PRIMARY KEY, state TEXT NOT NULL CHECK (state IN ('preparing','shown','removed')), " +
        "highest_reserved INTEGER NOT NULL DEFAULT 0, highest_indexed INTEGER NOT NULL DEFAULT 0, " +
        "local_identity BLOB, key_epoch INTEGER NOT NULL DEFAULT 1) WITHOUT ROWID",
        "CREATE UNIQUE INDEX active_binder_identity ON phone_binders(local_identity) WHERE state != 'removed'",
        "CREATE TABLE phone_views (binder TEXT NOT NULL REFERENCES phone_binders(binder), version INTEGER NOT NULL, " +
        "epoch INTEGER NOT NULL, name TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('uploading','uploaded')), " +
        "bytes BLOB NOT NULL, PRIMARY KEY(binder, version)) WITHOUT ROWID",
        "CREATE TABLE phone_item_snapshots (binder TEXT NOT NULL REFERENCES phone_binders(binder), id BLOB NOT NULL, " +
        "hash TEXT NOT NULL, changed_in INTEGER NOT NULL, PRIMARY KEY(binder, id)) WITHOUT ROWID",
        "CREATE TABLE publication_attempts (scope TEXT PRIMARY KEY, name TEXT NOT NULL, next TEXT NOT NULL, attempts INTEGER NOT NULL) WITHOUT ROWID",
        "CREATE TABLE decision_state (device TEXT PRIMARY KEY REFERENCES devices(device), tombstone_floor INTEGER NOT NULL DEFAULT 1, " +
        "outcomes_generation INTEGER NOT NULL DEFAULT 0, outcomes_built INTEGER NOT NULL DEFAULT 0, " +
        "outcomes_reserved INTEGER NOT NULL DEFAULT 0, outcomes_published INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID",
        "CREATE TABLE outcomes_upload (device TEXT PRIMARY KEY REFERENCES devices(device), revision INTEGER NOT NULL, changes INTEGER NOT NULL, " +
        "state TEXT NOT NULL CHECK (state IN ('uploading','published','superseded')), bytes BLOB NOT NULL) WITHOUT ROWID",
        "CREATE TABLE request_decisions (device TEXT PRIMARY KEY REFERENCES devices(device), request TEXT NOT NULL, bytes BLOB NOT NULL) WITHOUT ROWID",
        "CREATE TABLE outcome_tombstones (device TEXT NOT NULL REFERENCES devices(device), request TEXT NOT NULL, seq INTEGER NOT NULL, " +
        "outcome TEXT NOT NULL, decided_at TEXT NOT NULL, PRIMARY KEY(device, request)) WITHOUT ROWID",
        "CREATE TABLE decision_daily (device TEXT NOT NULL REFERENCES devices(device), day TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(device, day)) WITHOUT ROWID",
        "CREATE TABLE index_upload (slot INTEGER PRIMARY KEY CHECK (slot = 1), revision INTEGER NOT NULL, " +
        "epoch INTEGER NOT NULL, state TEXT NOT NULL CHECK (state IN ('uploading','published','superseded')), bytes BLOB NOT NULL)",
        "CREATE TABLE index_upload_views (binder TEXT PRIMARY KEY REFERENCES phone_binders(binder), version INTEGER NOT NULL) WITHOUT ROWID",
        "CREATE TABLE index_published_views (binder TEXT PRIMARY KEY REFERENCES phone_binders(binder), version INTEGER NOT NULL) WITHOUT ROWID"
    ])

    public init(database: URL, relay: CompanionRelayIdentity, secrets: any CompanionCredentialStorage) throws {
        self.relay = relay; self.secrets = secrets
        store = try StateStore.open(database, schema: Self.schema)
        // An existing profile for a different relay is never reset or used with another relay's credentials.
        _ = try store.read { try epoch($0) }
    }

    public func currentAccount() throws -> CompanionAccountEpoch? {
        try store.read { t in
            guard let number = try epoch(t) else { return nil }
            return CompanionAccountEpoch(number: number, key: try key(number))
        }
    }

    public func prepareAccount() throws -> CompanionAccountEpoch {
        try prepareAccount(beforeCommit: {})
    }
    // A thrown checkpoint proves that a key stored before a failed SQLite commit is reused on retry.
    func prepareAccount(beforeCommit: () throws -> Void, webOrigin: String? = nil) throws -> CompanionAccountEpoch {
        try store.write { t in
            if let number = try epoch(t) {
                if let webOrigin {
                    try t.execute("UPDATE profile SET web_origin = ? WHERE slot = 1 AND web_origin IS NULL", .text(webOrigin))
                    guard try t.rows("SELECT web_origin FROM profile WHERE slot = 1") == [[.text(webOrigin)]] else {
                        throw CompanionOwnerSetupError.reconfigurationRequired
                    }
                }
                try beforeCommit()
                return CompanionAccountEpoch(number: number, key: try key(number))
            }
            let account = keyAccount(1)
            if try secrets.read(account: account) == nil {
                let random = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                _ = try secrets.insert(account: account, bytes: random)
            }
            // Immutable, instance-scoped key slot: a failed earlier commit leaves a recoverable staged key.
            let storedKey = try key(1)
            try t.execute("INSERT INTO profile (slot, origin, instance, epoch, web_origin) VALUES (1, ?, ?, 1, ?)",
                          .text(relay.origin), .text(relay.instance), webOrigin.map { .text($0) } ?? .null)
            try beforeCommit()
            return CompanionAccountEpoch(number: 1, key: storedKey)
        }
    }

    func epoch(_ t: Transaction) throws -> Int64? {
        let rows = try t.rows("SELECT origin, instance, epoch FROM profile LIMIT 2")
        if rows.isEmpty { return nil }
        guard rows.count == 1, rows[0].count == 3,
              let origin = rows[0][0].text, origin.utf8.elementsEqual(relay.origin.utf8),
              let instance = rows[0][1].text, instance.utf8.elementsEqual(relay.instance.utf8),
              let number = rows[0][2].integer, number >= 1, number <= JSONNumber.maxSafeInteger else {
            throw CompanionCredentialError.invalid
        }
        return number
    }
    private func keyAccount(_ number: Int64) -> String { relay.account + ":account-key-v0:\(number)" }
    func key(_ number: Int64) throws -> SymmetricKey {
        guard let bytes = try secrets.read(account: keyAccount(number)) else { throw CompanionCredentialError.unavailable }
        guard bytes.count == 32 else { throw CompanionCredentialError.invalid }
        return SymmetricKey(data: bytes)
    }
}
