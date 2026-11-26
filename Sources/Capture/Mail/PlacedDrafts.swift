import Foundation
import SpravaKit

/// The approved fields of a placed draft, for comparison with Drafts and Sent (D48).
/// Keep this short-lived database out of backups along with its SQLite sidecars.
public struct PlacedDrafts {
    public static let lifetime: TimeInterval = 30 * 86_400
    public struct Record: Codable, Sendable {
        public let card: String
        public let account: String
        public let connection: UUID
        let binderInstance: String?
        public let binder: String
        public let placedAt: Date
        public let result: IMAPDraftAppend.Placed

        public func belongs(to config: BinderIMAPConnections.Configuration) -> Bool {
            account == DraftRequests.account(of: config.account)
                && (binderInstance.map { $0 == config.instance } ?? (connection == config.id))
        }
    }

    private let store: StateStore
    private static let schema = StateStore.Schema(version: 1, statements: [
        "CREATE TABLE drafts(card TEXT PRIMARY KEY, expires INTEGER NOT NULL, record BLOB NOT NULL) STRICT",
        "CREATE INDEX drafts_expiry ON drafts(expires)"
    ])

    public init(support: URL) throws {
        store = try StateStore.open(support.appendingPathComponent("capture/placed-drafts/records.sqlite"), schema: Self.schema)
        // Add the comparison table without discarding receipts from an earlier build.
        _ = try store.write { try $0.execute("""
            CREATE TABLE IF NOT EXISTS comparisons(
                card TEXT PRIMARY KEY REFERENCES drafts(card) ON DELETE CASCADE,
                next_check INTEGER, result BLOB
            ) STRICT
            """) }
    }

    public func record(_ request: DraftRequests.Request, connection: BinderIMAPConnections.Configuration, result: IMAPDraftAppend.Placed, at now: Date) throws {
        let record = Record(card: request.id, account: request.account, connection: connection.id, binderInstance: connection.instance, binder: request.binder,
                            placedAt: now, result: result)
        _ = try store.write { t in
            try t.execute("INSERT INTO drafts VALUES (?, ?, ?)", .text(request.id),
                          .integer(Int64(now.addingTimeInterval(Self.lifetime).timeIntervalSince1970)),
                          .blob(try JSONEncoder().encode(record)))
        }
    }

    /// Reconcile an interrupted cleanup before expiration, even if the runtime was away for 30 days.
    public func record(for request: DraftRequests.Request) throws -> Record? {
        try store.read { t in
            guard let row = try t.rows("SELECT record FROM drafts WHERE card = ?", .text(request.id)).first else { return nil }
            guard let data = row.first?.blob, let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.card == request.id, record.binder == request.binder, record.account == request.account
            else { throw DraftRequests.Refused.exists }
            return record
        }
    }

    /// Claim at most one due receipt. A disconnect or stopped worker retries later and lets the others through.
    public func nextReadBack(at now: Date) throws -> Record? {
        let time = Int64(now.timeIntervalSince1970)
        return try store.write { t in
            guard let row = try t.rows("""
                SELECT d.card, d.record FROM drafts d LEFT JOIN comparisons c ON d.card = c.card
                WHERE d.expires > ? AND (c.card IS NULL OR c.next_check <= ?)
                ORDER BY COALESCE(c.next_check, 0), d.expires LIMIT 1
                """, .integer(time), .integer(time)).first else { return nil }
            guard let id = row[0].text, let data = row[1].blob,
                  let record = try? JSONDecoder().decode(Record.self, from: data), record.card == id else { throw DraftRequests.Refused.missing }
            try t.execute("""
                INSERT INTO comparisons(card,next_check) VALUES(?,?)
                ON CONFLICT(card) DO UPDATE SET next_check=excluded.next_check
                """, .text(id), .integer(time + 900))
            return record
        }
    }

    public func checked(_ card: String, result: IMAPDraftReadBack.Result) throws {
        _ = try store.write { t in
            try t.execute("UPDATE comparisons SET result=?, next_check=CASE WHEN ? THEN next_check ELSE NULL END WHERE card=?",
                          .blob(try JSONEncoder().encode(result)), .integer(result.status == .missing ? 1 : 0), .text(card))
        }
    }

    public struct Comparison: Sendable {
        public let card: String
        public let subject: String
        public let result: IMAPDraftReadBack.Result?
    }

    public func comparisons(for config: BinderIMAPConnections.Configuration, at now: Date) throws -> [Comparison] {
        try store.read { t in
            // Scope inside the query so another connection's recipients and hashes never reach the page.
            try t.rows("""
                SELECT d.card, json_extract(CAST(d.record AS TEXT),'$.result.approved.subject'), c.result
                FROM drafts d LEFT JOIN comparisons c ON d.card=c.card
                WHERE d.expires > ? AND json_extract(CAST(d.record AS TEXT),'$.account')=?
                  AND (json_extract(CAST(d.record AS TEXT),'$.binderInstance')=?
                    OR (json_extract(CAST(d.record AS TEXT),'$.binderInstance') IS NULL
                      AND json_extract(CAST(d.record AS TEXT),'$.connection')=?))
                ORDER BY d.expires DESC LIMIT 100
                """, .integer(Int64(now.timeIntervalSince1970)), .text(DraftRequests.account(of: config.account)),
                     .text(config.instance), .text(config.id.uuidString)).map { row in
                guard let card = row[0].text, let subject = row[1].text else { throw DraftRequests.Refused.missing }
                return Comparison(card: card, subject: subject, result: try row[2].blob.map { try JSONDecoder().decode(IMAPDraftReadBack.Result.self, from: $0) })
            }
        }
    }

    public func expire(at now: Date) throws {
        _ = try store.write { try $0.execute("DELETE FROM drafts WHERE expires <= ?", .integer(Int64(now.timeIntervalSince1970))) }
    }
}
