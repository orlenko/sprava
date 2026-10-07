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

    /// What the clerk wants the person to know about one op: its flags, its guess when not sure, time words it
    /// could not turn into a date, and why it chose the binder (capture-event-v0 §6.4 check 5).
    public static func notes(_ op: JSONObject) -> [String] {
        guard let card = op["card"]?.objectValue else { return [] }
        var out = card["flags"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let guess = card["guess"]?.stringValue { out.append("the clerk's guess: \(guess) (not sure)") }
        if let related = card["related"]?.stringValue { out.append("possibly related to \u{201C}\(related)\u{201D}") }
        if let when = card["when_text"]?.stringValue { out.append("\u{201C}\(when)\u{201D} was not turned into a date; type one") }
        let signals = card["signals"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let words: [String: String] = ["hint": "you chose the binder", "binder_call": "the clerk picked it",
                                       "index_match": "the binder's words match", "neighbours": "the items around it went there"]
        let why = signals.compactMap { words[$0] }
        if !why.isEmpty, card["guess"] == nil { out.append("filed because " + why.joined(separator: ", ")) }
        return out
    }

    /// Every note for a card: each op's, plus the card's own (capture-event-v0 §3.2, §6.5).
    public var cardNotes: [String] {
        var out = ops.flatMap(Self.notes)
        if let already = raw["provenance"]?["already_in_binder"]?.arrayValue?.compactMap(\.stringValue), !already.isEmpty {
            out.append("already in the binder: " + already.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))
        }
        if let left = raw["provenance"]?["left_out"]?.arrayValue?.compactMap(\.stringValue), !left.isEmpty {
            out.append("left out, type them by hand: " + left.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))
        }
        if let remains = raw["provenance"]?["remains"]?.stringValue { out.append("still kept elsewhere: \(remains)") }
        if raw["provenance"]?["private"] == .bool(true) { out.append("private: kept off the hub and every brain") }
        return out
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
        case "file_document":
            let doc = args["document"]
            let path = doc?["path"]?.stringValue ?? "?"
            let sha = doc?["sha256"]?.stringValue.map { " · sha256 " + $0.prefix(12) + "…" } ?? ""
            let from = args["from"]?.stringValue.map { "Move \u{201C}\(($0 as NSString).lastPathComponent)\u{201D} from intake/ to " } ?? "Record "
            return from + path + sha
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

extension Proposal {
    static let touchingOps: Set<String> = ["update_item", "set_status", "complete", "drop", "dismiss", "undismiss"]

    /// The canonical hash of each existing item the ops touch, keyed by the id's canonical text.
    public static func fingerprints(_ ops: [JSONObject], catalog: JSONObject?) -> JSONObject {
        var out = JSONObject()
        for op in ops where touchingOps.contains(op["op"]?.stringValue ?? "") {
            guard let id = op["args"]?["id"], let key = try? Canonical.serialize(id),
                  let item = catalog?["open_items"]?.arrayValue?.first(where: { $0["id"] == id }),
                  let hash = try? Canonical.hash(item) else { continue }
            out.set(key, .string(hash))
        }
        return out
    }

    /// Items that changed since the card was made: their titles, for "needs a look" (architecture 4.6).
    public func changedSince(catalog: JSONObject?) -> [String] {
        guard let expect = raw["expect"]?.objectValue else { return [] }
        let items = catalog?["open_items"]?.arrayValue ?? []
        return expect.entries.compactMap { e in
            let item = items.first { (try? Canonical.serialize($0["id"] ?? .null)) == e.key }
            guard let item else { return "\(e.key) (no longer open)" }
            return (try? Canonical.hash(item)) == e.value.stringValue ? nil : (item["title"]?.stringValue ?? e.key)
        }
    }

    /// Whether two new records share one placeholder name, which would make later references ambiguous.
    public static func hasDuplicatePlaceholders(_ ops: [JSONObject]) -> Bool {
        var seen = Set<String>()
        for op in ops {
            guard let id = (op["args"]?["item"]?["id"] ?? op["args"]?["document"]?["id"])?.stringValue, id.hasPrefix("$new:") else { continue }
            if !seen.insert(id).inserted { return true }
        }
        return false
    }
}

/// The person's edits to a card before approval (mvp.md increment 3: Approve, Edit, Reject, Undo). Only the
/// fields a person can see on the card change; an op can be left out; nothing else is accepted.
public enum CardEdits {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// `edits` is `[{index, skip?, title?, due?, priority?, folder?}]`; `due` is a date, or "" for no deadline.
    public static func apply(_ edits: [JSONValue], to ops: [JSONObject]) throws -> [JSONObject] {
        var out = ops
        var skipped = Set<Int>()
        for e in edits {
            guard let i = e["index"]?.numberValue?.safeInteger.map(Int.init), out.indices.contains(i) else { throw Failure(message: "an edit names no op") }
            if e["skip"] == .bool(true) { skipped.insert(i); continue }
            guard var args = out[i]["args"]?.objectValue else { continue }
            switch out[i]["op"]?.stringValue {
            case "add_item":
                guard var item = args["item"]?.objectValue else { continue }
                if let t = e["title"]?.stringValue {
                    let title = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, title.count <= 200 else { throw Failure(message: "a title is one line of text") }
                    item.set("title", .string(title))
                }
                if let p = e["priority"]?.stringValue {
                    guard ["high", "normal", "low"].contains(p) else { throw Failure(message: "priority is high, normal or low") }
                    item.set("priority", .string(p))
                }
                if let d = e["due"]?.stringValue {
                    if d.isEmpty {
                        item.remove("due")
                        if item["status"]?.stringValue == "open" { item.set("no_deadline", .bool(true)) }
                    } else {
                        guard let date = CalendarDate.strict(d) else { throw Failure(message: "a date is written YYYY-MM-DD") }
                        item.set("due", .string(date.description))
                        item.remove("no_deadline")
                    }
                }
                args.set("item", .object(item))
            case "update_item":
                if let d = e["due"]?.stringValue, var set = args["set"]?.objectValue {
                    guard let date = CalendarDate.strict(d) else { throw Failure(message: "a date is written YYYY-MM-DD") }
                    set.set("due", .string(date.description))
                    args.set("set", .object(set))
                }
            default:
                break
            }
            out[i].set("args", .object(args))
        }
        let kept = out.enumerated().filter { !skipped.contains($0.offset) }.map(\.element)
        guard !kept.isEmpty else { throw Failure(message: "leave at least one change in, or reject the card") }
        return kept
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
        var raw = proposal.raw
        // On first save, the card records what it assumed about each existing item it touches (architecture 4.6).
        if raw["expect"] == nil, proposal.state == "proposed" {
            raw.set("expect", .object(Proposal.fingerprints(proposal.ops, catalog: Teka.read(folder).catalog)))
        }
        let data = Data(JSONWriter.pretty(.object(raw)).utf8)
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
        if Proposal.hasDuplicatePlaceholders(edited ?? proposal.ops) {
            throw Refused(reason: "two new records on this card share one placeholder name")
        }
        // A crash after the batch was written but before the card was marked: finish marking, apply nothing twice.
        // The binder is settled first, so a write cut short is rolled forward or aborted, and aborted lines never
        // count as applied.
        try settle(now: now)
        let log = try readOpLog().ops
        let aborted = Set(log.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        let already = log.filter { $0["proposal"]?.stringValue == proposal.id && !aborted.contains($0["id"]?.stringValue ?? "") }
        if !already.isEmpty {
            var raw = proposal.raw
            raw.set("state", .str("applied"))
            raw.set("applied_ops", .array(already.compactMap { $0["id"] }))
            try ProposalStore.save(Proposal(raw: raw), in: folder)
            return already
        }
        let changed = proposal.changedSince(catalog: try JSONParser.parse(try Data(contentsOf: folder.appendingPathComponent("catalog.json"))).value.objectValue)
        if !changed.isEmpty {
            throw Refused(reason: "needs a look: changed since this card was made: " + changed.joined(separator: ", "))
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
        if edited != nil { raw.set("edited", .bool(true)) }   // for the filing-quality measure (mvp.md 1.2)
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
