import BinderFormat
import Foundation
import SpravaKit

public enum CompanionOperationProof: Sendable, Equatable { case tookEffect, notApplied, unknown }

enum CompanionOperationTag {
    static func isValid(_ note: String?) -> Bool {
        guard let note, note.utf8.count == 55, note.hasPrefix("companion:") else { return false }
        let parts = note.dropFirst(10).split(separator: "/", omittingEmptySubsequences: false)
        func id(_ value: Substring) -> Bool {
            guard value.utf8.count == 22, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return false }
            let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="
            guard let bytes = Data(base64Encoded: padded), bytes.count == 16 else { return false }
            let encoded = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return encoded.utf8.elementsEqual(value.utf8)
        }
        return parts.count == 2 && id(parts[0]) && id(parts[1])
    }
}

extension TekaStore {
    /// companion-v0 §9.6: H = b and S = b cannot prove whether a phone op was applied and then restored.
    /// Abort the complete trailing write; never repeat it automatically. Other writes keep normal recovery.
    func abortCompanionWrite(_ trailing: [JSONObject], catalog: JSONObject, hash: String, now: Date) throws -> [JSONObject] {
        guard restoreMoves(trailing, catalog: catalog).isEmpty else {
            throw Refused(reason: "a companion write needs review; moved files could not be restored")
        }
        var abort = JSONObject()
        abort.set("id", .string(UUIDv7.make(now: now)))
        abort.set("at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
        abort.set("actor", .obj([("kind", .str("import")), ("client", .string(client))]))
        abort.set("before_hash", .string(hash)); abort.set("after_hash", .string(hash))
        abort.set("op", .str("abort"))
        abort.set("args", .obj([("ops", .array(trailing.compactMap { $0["id"] })), ("reason", .str("companion-review"))]))
        try appendLines([abort])
        lastAbsorbed = .aborted(trailing.count)
        return [abort]
    }
    /// Read-only companion-v0 §9.6 proof. Caller already holds the binder write lock and has settled recovery.
    /// No new lock, recovery, directory creation or writes occur here; incomplete recovery throws for retry.
    public func companionOperationProof(effectID: String, tag: String) throws -> CompanionOperationProof {
        guard UUID(uuidString: effectID)?.uuidString.lowercased() == effectID, CompanionOperationTag.isValid(tag) else {
            throw Refused(reason: "invalid companion effect identity")
        }
        try checkContainment()
        let log = try readOpLog().ops // Torn lines and incomplete batches are not proof that an op took effect.
        let matches = log.filter { $0["id"]?.stringValue == effectID }
        guard !matches.isEmpty else { return .notApplied }
        if matches.count != 1 || matches[0]["note"]?.stringValue != tag { return .unknown }
        if log.contains(where: { $0["op"] == .str("abort") && ($0["args"]?["ops"]?.arrayValue ?? []).contains(.string(effectID)) }) {
            return .unknown
        }
        let (catalog, hash, _) = try readCatalog()
        try Self.refuseUnknownLevel(catalog); try Self.refuseUnknownOps(log)
        let snapshot: Data
        switch SafeFile.read(snapshotURL, limit: Self.maxCatalogBytes) {
        case .ok(let bytes): snapshot = bytes
        default: throw Refused(reason: "companion recovery is unfinished; settle the binder first")
        }
        let parsed = try JSONParser.parse(snapshot)
        guard parsed.safety.isSafe, parsed.value.objectValue != nil,
              hash == log.last?["after_hash"]?.stringValue, try Canonical.hash(parsed.value) == hash else {
            throw Refused(reason: "companion recovery is unfinished; settle the binder first")
        }
        return .tookEffect
    }
}
