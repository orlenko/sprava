import Foundation
import SpravaKit

/// The durable pending-intent part of binder-v0 §7.2.2. This is internal owner state, not admission.
/// A future management operation must prove folder ownership under the binder lock BEFORE calling begin,
/// create and flush the claim exclusively, and reconcile both stores before issuing any capability.
/// No runtime caller is wired here. A copied claim, owner.json or path must never supply this proof.
final class BinderIdentityAllocations: Sendable {
    struct FolderInstance: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64

        // A locator for a verified instance, not a logical id or an ownership proof by itself.
        fileprivate var key: String { "\(device):\(inode):\(birthSeconds):\(birthNanoseconds)" }
        fileprivate var valid: Bool { inode > 0 && (0..<1_000_000_000).contains(birthNanoseconds) }
    }

    struct Pending: Sendable, Equatable {
        let requestID: UUID
        let binderID: UUID
        let instance: FolderInstance
    }

    enum Refused: Error { case invalidInstance, requestConflict, instanceAlreadyPending, damagedIntent }
    private let state: StateStore
    private static let schema = StateStore.Schema(version: 1, statements: [
        """
        CREATE TABLE binder_identity_allocations (
            request_id TEXT PRIMARY KEY NOT NULL CHECK(length(request_id) = 36),
            folder_instance TEXT UNIQUE NOT NULL CHECK(length(folder_instance) BETWEEN 7 AND 128),
            binder_id TEXT UNIQUE NOT NULL CHECK(length(binder_id) = 36)
        ) STRICT
        """
    ])

    /// Production ownership is binder-store/state.sqlite, outside every binder (code-structure §4.1).
    /// The explicit URL permits invented fixture state. Opening does not inspect or allocate a binder.
    init(at url: URL) throws { state = try StateStore.open(url, schema: Self.schema) }

    /// Lookups never create an allocation. Invalid existing state is never interpreted as absence.
    func pending(requestID: UUID) throws -> Pending? {
        try state.read { transaction in
            try Self.read(transaction, requestID: requestID)
        }
    }

    /// A committed pending intent survives a lost reply or restart with the SAME random id. There is no
    /// delete/remint or "admitted" operation here; the future owner must recover this exact intent.
    func begin(requestID: UUID, instance: FolderInstance) throws -> Pending {
        guard instance.valid else { throw Refused.invalidInstance }
        return try state.write { transaction in
            if let existing = try Self.read(transaction, requestID: requestID) {
                guard existing.instance == instance else { throw Refused.requestConflict }
                return existing
            }
            guard try transaction.rows(
                "SELECT 1 FROM binder_identity_allocations WHERE folder_instance = ? LIMIT 1",
                .text(instance.key)).isEmpty else { throw Refused.instanceAlreadyPending }
            let intent = Pending(requestID: requestID, binderID: UUID(), instance: instance)
            try transaction.execute(
                "INSERT INTO binder_identity_allocations (request_id, folder_instance, binder_id) VALUES (?, ?, ?)",
                .text(requestID.uuidString.lowercased()), .text(instance.key), .text(intent.binderID.uuidString.lowercased()))
            return intent
        }
    }

    private static func read(_ transaction: Transaction, requestID: UUID) throws -> Pending? {
        // Cap returned strings even if a damaged state file no longer has the declared CHECK constraints.
        let rows = try transaction.rows(
            """
            SELECT substr(folder_instance, 1, 129), substr(binder_id, 1, 37)
            FROM binder_identity_allocations WHERE request_id = ? LIMIT 2
            """, .text(requestID.uuidString.lowercased()))
        guard !rows.isEmpty else { return nil }
        guard rows.count == 1, rows[0].count == 2,
              let key = rows[0][0].text, key.utf8.count <= 128,
              let text = rows[0][1].text, text.utf8.count == 36,
              let id = UUID(uuidString: text), id.uuidString.lowercased() == text else { throw Refused.damagedIntent }
        let bytes = Array(text.utf8)
        guard bytes[14] == UInt8(ascii: "4"), "89ab".utf8.contains(bytes[19]) else { throw Refused.damagedIntent }
        let fields = key.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 4, let device = UInt64(fields[0]), let inode = UInt64(fields[1]),
              let seconds = Int64(fields[2]), let nanoseconds = Int64(fields[3]) else { throw Refused.damagedIntent }
        let instance = FolderInstance(device: device, inode: inode, birthSeconds: seconds, birthNanoseconds: nanoseconds)
        guard instance.valid, instance.key == key else { throw Refused.damagedIntent }
        return Pending(requestID: requestID, binderID: id, instance: instance)
    }
}
