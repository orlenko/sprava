import CryptoKit
import Foundation
import SpravaKit

public struct CompanionIndexPublication: Sendable {
    public let revision: Int64
    public let epoch: Int64
    public let bytes: Data
    public var name: String { "index/\(revision)" }
}
public enum CompanionPublicationError: Error, Equatable { case invalid, unavailable, tooManyBinders }

extension CompanionProfile {
    /// companion-v0 §9.7: one durable head, exact bytes before upload, monotone revisions and pairing floor.
    /// View membership is supplied by this target's recorded uploads, never by relay listings or binder paths.
    public func prepareIndex(generatedAt: String) throws -> CompanionIndexPublication {
        try prepareIndex(generatedAt: generatedAt, beforeCommit: {})
    }
    func prepareIndex(generatedAt: String, beforeCommit: () throws -> Void) throws -> CompanionIndexPublication {
        guard CompanionOwnerRelay.time(generatedAt) else { throw CompanionPublicationError.invalid }
        return try store.write { t in
            let counters = try indexCounters(t)
            if let head = try indexHead(t), head.state == "uploading" { return head.value }
            guard try claimState(t) == .claimed, let e = try epoch(t), counters.reserved < JSONNumber.maxSafeInteger,
                  try t.rows("SELECT 1 FROM recipients r JOIN devices d ON d.device = r.device " +
                             "WHERE r.epoch = ? AND d.state = 'revoked' LIMIT 1", .integer(e)).isEmpty else {
                throw CompanionPublicationError.unavailable
            }
            let revision = counters.reserved + 1
            let entries = try indexEntries(e, t)
            let plaintext = pairingJSON([("revision", number(revision)), ("generated_at", .string(generatedAt)),
                                         ("binders", .array(entries.map(\.json)))])
            guard plaintext.count <= 92700 else { throw CompanionPublicationError.invalid }
            guard let owner = try CompanionOwnerVault(backend: secrets).load(relay) else { throw CompanionCredentialError.unavailable }
            let name = "index/\(revision)"
            let bytes = try CompanionSealedObject.seal(name: name, epoch: e, key: key(e), plaintext: plaintext, signer: owner.signingKey)
            try t.execute("INSERT OR REPLACE INTO index_upload VALUES (1, ?, ?, 'uploading', ?)",
                          .integer(revision), .integer(e), .blob(bytes))
            try t.execute("UPDATE profile SET index_reserved = ? WHERE slot = 1", .integer(revision))
            try t.execute("DELETE FROM index_upload_views")
            for entry in entries {
                try t.execute("INSERT INTO index_upload_views VALUES (?, ?)", .text(entry.id), .integer(entry.version))
                try t.execute("UPDATE phone_binders SET highest_indexed = MAX(highest_indexed, ?) WHERE binder = ?",
                              .integer(entry.version), .text(entry.id))
            }
            try beforeCommit()
            return CompanionIndexPublication(revision: revision, epoch: e, bytes: bytes)
        }
    }
    public func pendingIndex() throws -> CompanionIndexPublication? {
        try store.read { t in
            _ = try indexCounters(t)
            guard let head = try indexHead(t), head.state == "uploading" else { return nil }
            return head.value
        }
    }
    /// Returns false for a superseded head. A late upload cannot publish an older floor or membership set.
    @discardableResult
    public func completeIndex(_ publication: CompanionIndexPublication) throws -> Bool {
        try store.write { t in
            _ = try indexCounters(t)
            guard let head = try indexHead(t) else { throw CompanionPublicationError.invalid }
            if publication.revision < head.value.revision { return false }
            try match(publication, head.value)
            if head.state == "superseded" { return false }
            if head.state == "published" { return true }
            try t.execute("UPDATE index_upload SET state = 'published' WHERE slot = 1")
            try t.execute("UPDATE profile SET index_published = ? WHERE slot = 1", .integer(publication.revision))
            try t.execute("DELETE FROM index_published_views")
            try t.execute("INSERT INTO index_published_views SELECT binder, version FROM index_upload_views")
            return true
        }
    }
    /// A 409 (or unexpected 410) retires the name; the next prepare reserves above every prior assignment.
    public func supersedeIndex(_ publication: CompanionIndexPublication) throws {
        try store.write { t in
            _ = try indexCounters(t)
            guard let head = try indexHead(t) else { throw CompanionPublicationError.invalid }
            if publication.revision < head.value.revision { return }
            try match(publication, head.value)
            if head.state == "uploading" { try t.execute("UPDATE index_upload SET state = 'superseded' WHERE slot = 1") }
        }
    }
    func binderKeyAccount(_ id: String, epoch: Int64) -> String { relay.account + ":binder-key-v0:\(id):\(epoch)" }
    private func match(_ a: CompanionIndexPublication, _ b: CompanionIndexPublication) throws {
        guard a.revision == b.revision, a.epoch == b.epoch, a.bytes == b.bytes else { throw CompanionPublicationError.invalid }
    }
    private func number(_ value: Int64) -> JSONValue { .number(JSONNumber(text: String(value))) }
    private func indexCounters(_ t: Transaction) throws -> (reserved: Int64, published: Int64) {
        guard try epoch(t) != nil,
              let r = try t.rows("SELECT index_reserved, index_published FROM profile WHERE slot = 1").first, r.count == 2,
              let reserved = r[0].integer, let published = r[1].integer,
              published >= 0, reserved >= published, reserved <= JSONNumber.maxSafeInteger else { throw CompanionPublicationError.invalid }
        return (reserved, published)
    }
    private func indexHead(_ t: Transaction) throws -> (value: CompanionIndexPublication, state: String)? {
        let counters = try indexCounters(t), rows = try t.rows("SELECT revision, epoch, state, bytes FROM index_upload WHERE slot = 1")
        guard let r = rows.first else {
            if counters.reserved != 0 { throw CompanionPublicationError.invalid }; return nil
        }
        guard r.count == 4, let revision = r[0].integer, revision == counters.reserved, revision >= 1,
              let e = r[1].integer, e >= 1, e <= JSONNumber.maxSafeInteger,
              let state = r[2].text, ["uploading", "published", "superseded"].contains(state),
              (state == "published") == (revision == counters.published),
              let bytes = r[3].blob, !bytes.isEmpty, bytes.count <= 1048576 else { throw CompanionPublicationError.invalid }
        return (CompanionIndexPublication(revision: revision, epoch: e, bytes: bytes), state)
    }
    private struct Entry {
        let id: String; let version: Int64; let json: JSONValue
    }
    private func indexEntries(_ e: Int64, _ t: Transaction) throws -> [Entry] {
        let rows = try t.rows("SELECT v.binder, v.version, v.name FROM phone_views v JOIN phone_binders b ON b.binder = v.binder " +
            "WHERE b.state = 'shown' AND v.state = 'uploaded' AND v.epoch = ? AND v.version = " +
            "(SELECT MAX(w.version) FROM phone_views w WHERE w.binder = v.binder AND w.state = 'uploaded' AND w.epoch = v.epoch) " +
            "ORDER BY v.binder LIMIT 101", .integer(e))
        guard rows.count <= 100 else { throw CompanionPublicationError.tooManyBinders }
        return try rows.map { row in
            guard row.count == 3, let id = row[0].text, CompanionWire.isID(id), let version = row[1].integer,
                  version >= 1, version <= JSONNumber.maxSafeInteger, let name = row[2].text, !name.isEmpty else { throw CompanionPublicationError.invalid }
            guard let kb = try secrets.read(account: binderKeyAccount(id, epoch: e)) else { throw CompanionCredentialError.unavailable }
            guard kb.count == 32 else { throw CompanionCredentialError.invalid }
            return Entry(id: id, version: version, json: .object(JSONObject([
                ("id", .string(id)), ("name", .string(Self.phoneName(name))), ("view_version", number(version)),
                ("key", .string(CompanionWire.base64(kb)))
            ])))
        }
    }
    // companion-v0 §8.4: truncate on scalar boundaries and include the ellipsis in both text budgets.
    static func phoneName(_ text: String) -> String {
        func encoded(_ value: String) -> Int { JSONWriter.compact(.string(value)).utf8.count - 2 }
        let scalars = Array(text.unicodeScalars.prefix(201))
        let bounded = String(String.UnicodeScalarView(scalars))
        if scalars.count <= 200 && encoded(bounded) <= 800 { return bounded }
        var prefix = String.UnicodeScalarView()
        for scalar in scalars.prefix(199) {
            let candidate = String(prefix) + String(scalar) + "…"
            if encoded(candidate) > 800 { break }
            prefix.append(scalar)
        }
        return String(prefix) + "…"
    }
}
