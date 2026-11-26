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
        public let binder: String
        public let placedAt: Date
        public let result: IMAPDraftAppend.Placed
    }

    private let store: StateStore
    private static let schema = StateStore.Schema(version: 1, statements: [
        "CREATE TABLE drafts(card TEXT PRIMARY KEY, expires INTEGER NOT NULL, record BLOB NOT NULL) STRICT",
        "CREATE INDEX drafts_expiry ON drafts(expires)"
    ])

    public init(support: URL) throws {
        store = try StateStore.open(support.appendingPathComponent("capture/placed-drafts/records.sqlite"), schema: Self.schema)
    }

    public func record(_ request: DraftRequests.Request, connection: UUID, result: IMAPDraftAppend.Placed, at now: Date) throws {
        let record = Record(card: request.id, account: request.account, connection: connection, binder: request.binder,
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

    public func expire(at now: Date) throws {
        _ = try store.write { try $0.execute("DELETE FROM drafts WHERE expires <= ?", .integer(Int64(now.timeIntervalSince1970))) }
    }
}
