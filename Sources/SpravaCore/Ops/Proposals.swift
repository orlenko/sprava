import CryptoKit
import Foundation

/// A proposal: a batch of op bodies waiting for the person, stored as `.sprava/proposals/<id>.json` and
/// rewritten on each state change (teka-v0 §6.5). The runtime records each file's digest so a proposal file
/// rewritten by another program is noticed (architecture 4.6).
public struct Proposal: Sendable {
    public var raw: JSONObject

    public var id: String { raw["id"]?.stringValue ?? "" }
    public var state: String { raw["state"]?.stringValue ?? "" }
    public var title: String { raw["title"]?.stringValue ?? "(untitled change)" }
    public var actor: JSONObject { raw["actor"]?.objectValue ?? JSONObject() }
    public var ops: [JSONObject] { raw["ops"]?.arrayValue?.compactMap(\.objectValue) ?? [] }

    public init(raw: JSONObject) { self.raw = raw }

    public static func make(title: String, actor: JSONObject, ops: [JSONObject], confidence: Double? = nil,
                            provenance: JSONObject? = nil, now: Date = Date()) -> Proposal {
        var p = JSONObject()
        p.set("id", .string(UUIDv7.make(now: now)))
        p.set("format_version", .str("0"))
        p.set("created_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
        p.set("actor", .object(actor))
        p.set("state", .str("proposed"))
        p.set("title", .string(title))
        if let confidence { p.set("confidence", .number(JSONNumber(text: String(format: "%.2f", confidence)))) }
        if let provenance { p.set("provenance", .object(provenance)) }
        p.set("ops", .array(ops.map(JSONValue.object)))
        return Proposal(raw: p)
    }

    /// A short plain-words line for one op, for review cards (titles stay inside the app, never in logs).
    public static func describe(_ op: JSONObject, catalog: JSONObject?) -> String {
        let args = op["args"]?.objectValue ?? JSONObject()
        func title(of id: JSONValue?) -> String {
            guard let id, let item = catalog?["open_items"]?.arrayValue?.first(where: { $0["id"] == id }) else {
                return id.map(canonicalText) ?? "?"
            }
            return item["title"]?.stringValue ?? canonicalText(id)
        }
        switch op["op"]?.stringValue {
        case "add_item": return "Add \u{201C}\(args["item"]?["title"]?.stringValue ?? "?")\u{201D}" + (args["item"]?["due"]?.stringValue.map { ", due \($0)" } ?? "")
        case "complete": return args["next_due"] != nil ? "Mark one occurrence done: \u{201C}\(title(of: args["id"]))\u{201D}" : "Close as done: \u{201C}\(title(of: args["id"]))\u{201D}"
        case "drop": return "Drop: \u{201C}\(title(of: args["id"]))\u{201D}"
        case "set_status": return "Set \u{201C}\(title(of: args["id"]))\u{201D} to \(args["status"]?.stringValue ?? "?")" + (args["waiting_on"]?.stringValue.map { ", waiting on \($0)" } ?? "")
        case "update_item":
            let fields = (args["set"]?.objectValue?.keys ?? []) + (args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            return "Change \(fields.joined(separator: ", ")) of \u{201C}\(title(of: args["id"]))\u{201D}"
        case "migrate":
            let changes = (args["patch"]?.arrayValue ?? []).compactMap { step -> String? in
                guard let path = step["path"]?.stringValue else { return nil }
                let field = path.split(separator: "/").joined(separator: ".")
                return step["value"].map { "\(field) = \(canonicalText($0).prefix(40))" } ?? field
            }
            return "Stamp the catalog as teka v0: " + (changes.isEmpty ? "no changes" : changes.joined(separator: ", "))
        case "set_meta": return "Set " + (args["set"]?.objectValue?.keys.joined(separator: ", ") ?? "binder settings")
        case let other?: return other.replacingOccurrences(of: "_", with: " ")
        case nil: return "?"
        }
    }
}

public enum ProposalStore {
    public struct Tampered: Error, CustomStringConvertible {
        public let id: String
        public var description: String { "proposal \(id) was changed by another program" }
    }

    static func dir(_ folder: URL) -> URL { folder.appendingPathComponent(".sprava/proposals", isDirectory: true) }

    static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the proposal and returns the file's digest, which the caller records in its own state.
    @discardableResult
    public static func save(_ proposal: Proposal, in folder: URL) throws -> String {
        try AtomicFile.makePrivateFolder(dir(folder))
        let data = Data(JSONWriter.pretty(.object(proposal.raw)).utf8)
        try AtomicFile.write(data, to: dir(folder).appendingPathComponent("\(proposal.id).json"))
        return digest(data)
    }

    /// Every proposal in the binder, with its file digest. Unreadable files are skipped.
    public static func list(in folder: URL) -> [(Proposal, String)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir(folder).path) else { return [] }
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: dir(folder).appendingPathComponent(name)),
                  case .object(let o)? = try? JSONParser.parse(data).value else { return nil }
            return (Proposal(raw: o), digest(data))
        }
    }

    public static func load(_ id: String, in folder: URL, expectedDigest: String?) throws -> Proposal {
        let data = try Data(contentsOf: dir(folder).appendingPathComponent("\(id).json"))
        if let expectedDigest, digest(data) != expectedDigest { throw Tampered(id: id) }
        guard case .object(let o) = try JSONParser.parse(data).value else { throw Tampered(id: id) }
        return Proposal(raw: o)
    }
}

extension TekaStore {
    /// Approves a proposal and applies its ops as one batch (teka-v0 §6.5). `edited` replaces the ops when the
    /// person changed them on the card. A rejected batch leaves the proposal `proposed`.
    @discardableResult
    public func approve(_ proposal: Proposal, edited: [JSONObject]? = nil, approvedBy: String = "user",
                        now: Date = Date()) throws -> [JSONObject] {
        guard proposal.state == "proposed" else { throw Refused(reason: "proposal is \(proposal.state), not proposed") }
        // Facts are recorded by Sprava itself, never approved from a card.
        let facts: Set<String> = ["import_snapshot", "external_edit", "abort", "expunge"]
        if let bad = (edited ?? proposal.ops).first(where: { facts.contains($0["op"]?.stringValue ?? "") }) {
            throw Refused(reason: "\(bad["op"]?.stringValue ?? "?") is never approved from a card")
        }
        let actor = proposal.actor
        // A crash after the batch was written but before the card was marked: finish marking, apply nothing twice.
        let already = try readOpLog().ops.filter { $0["proposal"]?.stringValue == proposal.id }
        if !already.isEmpty {
            var raw = proposal.raw
            raw.set("state", .str("applied"))
            raw.set("applied_ops", .array(already.compactMap { $0["id"] }))
            try ProposalStore.save(Proposal(raw: raw), in: folder)
            return already
        }
        let catalog = try JSONParser.parse(try Data(contentsOf: folder.appendingPathComponent("catalog.json"))).value.objectValue ?? JSONObject()
        let resolved = Placeholders.resolve(edited ?? proposal.ops, catalog: catalog, opLog: try readOpLog().ops,
                                            year: Calendar(identifier: .gregorian).component(.year, from: now),
                                            at: ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!))
        let bodies = resolved.map { op in
            OpBody(op: op["op"]?.stringValue ?? "", args: op["args"]?.objectValue ?? JSONObject(), actor: actor,
                   extra: [("proposal", .string(proposal.id)), ("approved_by", .string(approvedBy))]
                       + (op["note"].map { [("note", $0)] } ?? []))
        }
        let applied = try apply(bodies, batch: proposal.id, now: now)
        var raw = proposal.raw
        raw.set("state", .str("applied"))
        raw.set("applied_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
        raw.set("applied_ops", .array(applied.compactMap { $0["id"] }))
        try ProposalStore.save(Proposal(raw: raw), in: folder)
        return applied
    }

    public func reject(_ proposal: Proposal, reason: String? = nil, now: Date = Date()) throws {
        var raw = proposal.raw
        raw.set("state", .str("rejected"))
        raw.set("rejected_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
        if let reason { raw.set("rejected_reason", .string(reason)) }
        try ProposalStore.save(Proposal(raw: raw), in: folder)
    }
}
