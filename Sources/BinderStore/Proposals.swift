import BinderFormat
import CryptoKit
import Darwin
import Foundation
import SpravaKit

/// A proposal: a batch of op bodies waiting for the person, stored as `.sprava/proposals/<id>.json` and
/// rewritten on each state change (binder-v0 §6.5). The runtime records each file's digest so a proposal file
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
        out += intakeNotes
        if raw["provenance"]?["private"] == .bool(true) { out.append("private: kept off the hub and every brain") }
        return out
    }

    /// What code and the clerk found in an intake file (docs/adaptation-layer.md §4), in plain words.
    public var intakeNotes: [String] {
        guard let intake = raw["provenance"]?["intake"] else { return [] }
        var out: [String] = []
        if let held = intake["held"]?.stringValue { out.append("held, not read: \(held). File it as it is, or take it out of intake/") }
        if let reading = raw["provenance"]?["reading"] {
            let classes = ["governing": "a document that sets rules or obligations", "action": "asks you to do something",
                           "information": "a record to keep", "unsure": "the clerk is not sure what it is"]
            if let c = reading["class"]?.stringValue, let words = classes[c] { out.append("the clerk reads it as \(words)") }
            if let s = reading["summary"]?.stringValue { out.append("the clerk\u{2019}s summary, in its own words: \(s)") }
            if reading["reply_needed"] == .bool(true) { out.append("a reply may be needed") }
            if let n = reading["unread_windows"]?.numberValue?.safeInteger, n > 0 { out.append("the clerk read only part of it") }
        }
        if let preview = intake["preview"]?.stringValue { out.append("begins: \u{201C}\(preview)\u{201D}") }
        if intake["text_from"] == .str("ocr") { out.append("read from a scan: check names and numbers against the file") }
        if let facts = intake["facts"] {
            var found: [String] = []
            if let d = facts["dates"]?.arrayValue?.compactMap(\.stringValue), !d.isEmpty { found.append("dates " + d.joined(separator: ", ")) }
            if let a = facts["amounts"]?.arrayValue?.compactMap(\.stringValue), !a.isEmpty { found.append("amounts " + a.joined(separator: ", ")) }
            if let r = facts["references"]?.arrayValue?.compactMap(\.stringValue), !r.isEmpty { found.append("references " + r.joined(separator: ", ")) }
            if !found.isEmpty { out.append("found in it: " + found.joined(separator: "; ")) }
        }
        for n in intake["notes"]?.arrayValue?.compactMap(\.stringValue) ?? [] { out.append(n) }
        if intake["mismatch"] == .bool(true) { out.append("its name says one kind of file and its contents another") }
        let obtained = intake["obtained"]
        if let from = obtained?["from"]?.stringValue { out.append("from \(from)") }
        if obtained?["channel"]?.stringValue == "other" { out.append("how did this reach you? Say so when you approve") }
        if let why = raw["provenance"]?["escalate"]?.arrayValue?.compactMap(\.stringValue), !why.isEmpty {
            out.append("a careful reading is recommended: " + why.joined(separator: "; "))
        }
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
            // Every value the op would write is shown before approval, old and new (architecture 4.6).
            let item = args["id"].flatMap { id in catalog?["open_items"]?.arrayValue?.first { $0["id"] == id } }?.objectValue
            func short(_ v: JSONValue) -> String { String(canonicalText(v).prefix(60)) }
            var parts: [String] = []
            for e in args["set"]?.objectValue?.entries ?? [] {
                if let old = item?[e.key], old != e.value { parts.append("\(e.key): \(short(old)) -> \(short(e.value))") }
                else { parts.append("\(e.key): \(short(e.value))") }
            }
            for field in args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                parts.append("remove \(field)" + (item?[field].map { " (was \(short($0)))" } ?? ""))
            }
            let line = "Change \u{201C}\(title(of: args["id"]))\u{201D}: " + parts.joined(separator: "; ")
            return loosens(args, item: item) ? line + " \u{2014} a privacy change: the hub may receive more" : line
        case "set_disclosure":
            let level = args["disclosure"]?.stringValue ?? "?"
            // Not lower than the catalog's level: a raise, or a privacy card confirming a raise made outside.
            let current = PrivacyRatchet.level(catalog?["meta"]?["disclosure"])
            let wider = level != "none" && PrivacyRatchet.narrower(current, level) == current
            return "Set disclosure to \(level)" + (wider
                ? " \u{2014} a privacy change: the hub may receive more" : "")
                + " (what the hub already received is not recalled)"
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
            let stamps = (args["patch"]?.arrayValue ?? []).contains { $0["path"] == .str("/meta/format_version") }
            return (stamps ? "Stamp the catalog as binder v0: " : "Migrate the catalog: ")
                + (changes.isEmpty ? "no changes" : changes.joined(separator: ", "))
        case "set_meta": return "Set " + (args["set"]?.objectValue?.keys.joined(separator: ", ") ?? "binder settings")
        case let other?: return other.replacingOccurrences(of: "_", with: " ")
        case nil: return "?"
        }
    }

    /// Whether an `update_item` loosens what the hub may receive (binder-v0 §5.5): `redact` cleared, `slice_title`
    /// removed or changed, or, on a redacted item, a tag added or the kind removed.
    static func loosens(_ args: JSONObject, item: JSONObject?) -> Bool {
        let set = args["set"]?.objectValue ?? JSONObject()
        let unset = args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if unset.contains("redact") || (set["redact"].map { $0 != .bool(true) } ?? false) { return true }
        if unset.contains("slice_title") || set["slice_title"] != nil { return true }
        guard item?["redact"] == .bool(true) else { return false }
        if unset.contains("kind") { return true }
        let before = Set(item?["tags"]?.arrayValue ?? [])
        return set["tags"]?.arrayValue.map { !Set($0).isSubset(of: before) } ?? false
    }
}

extension Proposal {
    static let touchingOps: Set<String> = ["update_item", "set_status", "complete", "drop", "dismiss", "undismiss"]
    /// The prefix of a document's fingerprint key. No canonical id starts with a letter, nor does a pointer.
    static let documentKey = "document:"

    /// The canonical hash of each existing item the ops touch, keyed by the id's canonical text; of each document an
    /// `update_document` changes, keyed by `document:` and its id; and of each catalog value a `set_meta` or
    /// `migrate` writes or removes, keyed by its JSON pointer (`absent` when there is none), so a card that moves a
    /// meta value aside never removes one written since. A pointer starts with `/`, which no canonical id does.
    public static func fingerprints(_ ops: [JSONObject], catalog: JSONObject?) -> JSONObject {
        var out = JSONObject()
        for op in ops where touchingOps.contains(op["op"]?.stringValue ?? "") {
            guard let id = op["args"]?["id"], let key = try? Canonical.serialize(id),
                  let item = catalog?["open_items"]?.arrayValue?.first(where: { $0["id"] == id }),
                  let hash = try? Canonical.hash(item) else { continue }
            out.set(key, .string(hash))
        }
        // A document record a card changes, keyed apart from items, whose ids may be the same text.
        for op in ops where op["op"] == .str("update_document") {
            guard let id = op["args"]?["id"], let key = try? Canonical.serialize(id),
                  let document = catalog?["documents"]?.arrayValue?.first(where: { $0["id"] == id }),
                  let hash = try? Canonical.hash(document) else { continue }
            out.set(documentKey + key, .string(hash))
        }
        for op in ops {
            let args = op["args"]?.objectValue ?? JSONObject()
            var pointers: [String] = []
            switch op["op"]?.stringValue {
            case "set_meta":
                let keys = (args["set"]?.objectValue?.keys ?? []) + (args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                pointers = keys.map { "/meta/" + JSONPatch.escape($0) }
            case "migrate": pointers = args["patch"]?.arrayValue?.compactMap { $0["path"]?.stringValue } ?? []
            default: continue
            }
            for pointer in pointers where pointer.hasPrefix("/") && out[pointer] == nil {
                out.set(pointer, .string(metaFingerprint(pointer, in: catalog)))
            }
        }
        return out
    }

    /// The canonical hash of the value at `pointer`, or `absent`.
    static func metaFingerprint(_ pointer: String, in catalog: JSONObject?) -> String {
        guard let catalog, let value = JSONPatch.value(at: pointer, in: .object(catalog)) else { return "absent" }
        return (try? Canonical.hash(value)) ?? "unreadable"
    }

    /// Items that changed since the card was made: their titles, for "needs a look" (architecture 4.6). A catalog
    /// value the card writes or removes is named by its place, `meta.lifecycle` say.
    public func changedSince(catalog: JSONObject?) -> [String] {
        guard let expect = raw["expect"]?.objectValue else { return [] }
        let items = catalog?["open_items"]?.arrayValue ?? []
        return expect.entries.compactMap { e in
            if e.key.hasPrefix("/") {
                guard Proposal.metaFingerprint(e.key, in: catalog) != e.value.stringValue else { return nil }
                return (try? JSONPatch.tokens(e.key))?.joined(separator: ".") ?? e.key
            }
            if e.key.hasPrefix(Proposal.documentKey) {
                let id = String(e.key.dropFirst(Proposal.documentKey.count))
                let document = catalog?["documents"]?.arrayValue?.first { (try? Canonical.serialize($0["id"] ?? .null)) == id }
                guard let document else { return "document \(id) (no longer recorded)" }
                return (try? Canonical.hash(document)) == e.value.stringValue ? nil : (document["title"]?.stringValue ?? id)
            }
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

    /// The fields each op can take from the card. An edit to any other field, or to an op not listed, is refused,
    /// never dropped: what the person typed is either applied or reported.
    static let editable: [String: Set<String>] = ["add_item": ["title", "due", "priority"],
                                                  "update_item": ["title", "due", "priority", "waiting_on", "kind"]]

    /// `edits` is `[{index, skip?, title?, due?, priority?, waiting_on?, kind?}]`; `due` is a date, or "" for no
    /// deadline; `kind` is one of the closed list (binder-v0 §4.4).
    public static func apply(_ edits: [JSONValue], to ops: [JSONObject]) throws -> [JSONObject] {
        var out = ops
        var skipped = Set<Int>()
        for e in edits {
            guard let i = e["index"]?.numberValue?.safeInteger.map(Int.init), out.indices.contains(i) else { throw Failure(message: "an edit names no op") }
            if e["skip"] == .bool(true) { skipped.insert(i); continue }
            let fields = e.objectValue?.keys.filter { $0 != "index" && $0 != "skip" } ?? []
            let carried = editable[out[i]["op"]?.stringValue ?? ""] ?? []
            if let field = fields.first(where: { !carried.contains($0) || e[$0]?.stringValue == nil }) {
                throw Failure(message: carried.contains(field) ? "\(field) is written as text" : "this change cannot take a new \(field)")
            }
            guard !fields.isEmpty else { continue }
            guard var args = out[i]["args"]?.objectValue else { throw Failure(message: "this change cannot be edited") }
            switch out[i]["op"]?.stringValue {
            case "add_item":
                guard var item = args["item"]?.objectValue else { throw Failure(message: "this change cannot be edited") }
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
                        // Every status needs a due or no_deadline (binder-v0 §4.4), waiting and blocked too.
                        item.remove("due")
                        item.set("no_deadline", .bool(true))
                    } else {
                        guard let date = CalendarDate.strict(d) else { throw Failure(message: "a date is written YYYY-MM-DD") }
                        item.set("due", .string(date.description))
                        item.remove("no_deadline")
                    }
                }
                args.set("item", .object(item))
            case "update_item":
                // A repair card asks for what is missing: a due date or none, a party, a priority, a kind (binder-v0 §9.4);
                // a change of title is the person's correction of the proposed one.
                var set = args["set"]?.objectValue ?? JSONObject()
                var unset = args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
                func clear(_ key: String) {
                    set.remove(key)
                    if !unset.contains(key) { unset.append(key) }
                }
                if let t = e["title"]?.stringValue {
                    let title = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, title.count <= 200 else { throw Failure(message: "a title is one line of text") }
                    unset.removeAll { $0 == "title" }
                    set.set("title", .string(title))
                }
                if let d = e["due"]?.stringValue {
                    if d.isEmpty {
                        clear("due")
                        unset.removeAll { $0 == "no_deadline" }
                        set.set("no_deadline", .bool(true))
                    } else {
                        guard let date = CalendarDate.strict(d) else { throw Failure(message: "a date is written YYYY-MM-DD") }
                        unset.removeAll { $0 == "due" }
                        set.set("due", .string(date.description))
                        clear("no_deadline")
                    }
                }
                if let w = e["waiting_on"]?.stringValue {
                    let party = w.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !party.isEmpty, party.count <= 200 else { throw Failure(message: "who it waits on is one line of text") }
                    unset.removeAll { $0 == "waiting_on" }
                    set.set("waiting_on", .string(party))
                }
                if let p = e["priority"]?.stringValue {
                    guard ["high", "normal", "low"].contains(p) else { throw Failure(message: "priority is high, normal or low") }
                    unset.removeAll { $0 == "priority" }
                    set.set("priority", .string(p))
                }
                if let k = e["kind"]?.stringValue {
                    guard ItemRules.kinds.contains(k) else {
                        throw Failure(message: "kind is one of " + ItemRules.kinds.sorted().joined(separator: ", "))
                    }
                    unset.removeAll { $0 == "kind" }
                    set.set("kind", .string(k))
                }
                args.set("set", .object(set))
                if unset.isEmpty { args.remove("unset") } else { args.set("unset", .array(unset.map(JSONValue.string))) }
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

    package static func dir(_ folder: URL) -> URL { folder.appendingPathComponent(".sprava/proposals", isDirectory: true) }

    /// A proposal id as `Proposal.make` writes it: a UUID in lowercase hex. Only such an id names a card's file,
    /// so no id read from a card can reach outside the proposals folder (binder-v0 §3.6).
    public static func isValidID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard bytes.count == 36 else { return false }
        for (i, b) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(i) { if b != UInt8(ascii: "-") { return false }; continue }
            guard (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) else { return false }
        }
        return true
    }

    struct BadID: Error, CustomStringConvertible {
        var description: String { "a proposal's id is not one Sprava makes" }
    }

    /// `.sprava` and `.sprava/proposals` as real folders, never links, so no card is written or read outside the
    /// binder (binder-v0 §3.6). Missing ones are made 0700 when `create` is set, one level at a time.
    package static func checkedDir(_ folder: URL, create: Bool) throws -> URL {
        for url in [folder.appendingPathComponent(".sprava", isDirectory: true), dir(folder)] {
            var st = stat()
            if lstat(url.path, &st) == 0 {
                guard st.st_mode & S_IFMT == S_IFDIR else {
                    throw TekaStore.Refused(reason: (url.lastPathComponent == "proposals" ? ".sprava/proposals" : ".sprava") + " is not a regular folder")
                }
                continue
            }
            guard errno == ENOENT, create else { throw TekaStore.Refused(reason: "the proposals folder cannot be read") }
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw TekaStore.Refused(reason: "the proposals folder cannot be made") }
        }
        return dir(folder)
    }

    static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The digest of the bytes this process last wrote for each card, by folder and id. A card is trusted from
    /// these, never from a read of its file afterwards, which another program could have replaced in between
    /// (architecture 4.6).
    private static let writtenLock = NSLock()
    nonisolated(unsafe) private static var written: [String: String] = [:]

    static func writtenKey(_ id: String, in folder: URL) -> String { folder.standardizedFileURL.path + "#" + id }

    /// The digest of the bytes `save` last wrote for this card in this process; nil when it wrote none.
    package static func writtenDigest(_ id: String, in folder: URL) -> String? {
        writtenLock.withLock { written[writtenKey(id, in: folder)] }
    }

    /// Writes the proposal and returns the file's digest, which the caller records in its own state.
    @discardableResult
    public static func save(_ proposal: Proposal, in folder: URL) throws -> String {
        guard isValidID(proposal.id) else { throw BadID() }
        let target = try checkedDir(folder, create: true)
        var raw = proposal.raw
        // On first save, the card records what it assumed about each existing item it touches (architecture 4.6).
        if raw["expect"] == nil, proposal.state == "proposed" {
            raw.set("expect", .object(Proposal.fingerprints(proposal.ops, catalog: Teka.read(folder).catalog)))
        }
        let data = Data(JSONWriter.pretty(.object(raw)).utf8)
        try AtomicFile.write(data, to: target.appendingPathComponent("\(proposal.id).json"))
        let d = digest(data)
        writtenLock.withLock { written[writtenKey(proposal.id, in: folder)] = d }
        return d
    }

    /// Every proposal in the binder, with its file digest. Unreadable files are skipped, and so are links, FIFOs and
    /// anything else that is not a regular file, and a file whose name is not `<id>.json` for the id inside it; a
    /// linked folder lists nothing.
    public static func list(in folder: URL) -> [(Proposal, String)] {
        guard let dir = try? checkedDir(folder, create: false),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") && isValidID(String($0.dropLast(5))) }.sorted().compactMap { name in
            guard case .ok(let data) = SafeFile.read(dir.appendingPathComponent(name)),
                  case .object(let o)? = try? JSONParser.parse(data).value,
                  o["id"]?.stringValue == String(name.dropLast(5)) else { return nil }
            return (Proposal(raw: o), digest(data))
        }
    }

    public static func load(_ id: String, in folder: URL, expectedDigest: String?) throws -> Proposal {
        guard isValidID(id) else { throw BadID() }
        // Never through a link and never blocking on a FIFO: only a regular file in the binder is a card (§3.6).
        let data: Data
        switch SafeFile.read(try checkedDir(folder, create: false).appendingPathComponent("\(id).json")) {
        case .ok(let d): data = d
        case .missing: throw CocoaError(.fileReadNoSuchFile)
        case .refused: throw Tampered(id: id)
        case .unreadable: throw CocoaError(.fileReadUnknown)
        }
        if let expectedDigest, digest(data) != expectedDigest { throw Tampered(id: id) }
        guard case .object(let o) = try JSONParser.parse(data).value, o["id"]?.stringValue == id else { throw Tampered(id: id) }
        return Proposal(raw: o)
    }
}

extension TekaStore {
    /// Approves a proposal and applies its ops as one batch (binder-v0 §6.5). `edited` replaces the ops when the
    /// person changed them on the card. A rejected batch leaves the proposal `proposed`.
    @discardableResult
    public func approve(_ proposal: Proposal, edited: [JSONObject]? = nil, approvedBy: String = "user",
                        now: Date = Date()) throws -> [JSONObject] {
        guard proposal.state == "proposed" else { throw Refused(reason: "proposal is \(proposal.state), not proposed") }
        // A card that only reports lost changes is never applied in part (binder-v0 §6.7 step 6).
        guard proposal.raw["provenance"]?["manual_repair"] != .bool(true) else {
            throw Refused(reason: "this change has to be repaired by hand; reject the card once it is done")
        }
        guard !(edited ?? proposal.ops).isEmpty else { throw Refused(reason: "this card has no change to apply") }
        // Facts are recorded by Sprava itself, never approved from a card.
        let facts: Set<String> = ["import_snapshot", "external_edit", "abort", "expunge"]
        if let bad = (edited ?? proposal.ops).first(where: { facts.contains($0["op"]?.stringValue ?? "") }) {
            throw Refused(reason: "\(bad["op"]?.stringValue ?? "?") is never approved from a card")
        }
        let actor = proposal.actor
        if Proposal.hasDuplicatePlaceholders(edited ?? proposal.ops) {
            throw Refused(reason: "two new records on this card share one placeholder name")
        }
        // The card's `expect` is checked, and its placeholders minted, against the catalog the batch is applied to,
        // under the lock and after outside edits were absorbed (architecture 4.2 step 4).
        func bodies(_ catalog: JSONObject, _ log: [JSONObject]) throws -> [OpBody] {
            // A crash after the batch was written but before the card was marked, or another writer that approved the
            // card first: finish marking, apply nothing twice. Decided under the lock that writes the batch, on the
            // log as settled there, so a write cut short is rolled forward or aborted first, and aborted lines never
            // count as applied.
            let aborted = Set(log.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
            let already = log.filter { $0["proposal"]?.stringValue == proposal.id && !aborted.contains($0["id"]?.stringValue ?? "") }
            if !already.isEmpty { throw AlreadyApplied(lines: already) }
            let changed = proposal.changedSince(catalog: catalog)
            if !changed.isEmpty {
                throw Refused(reason: "needs a look: changed since this card was made: " + changed.joined(separator: ", "))
            }
            let resolved = try Placeholders.resolve(edited ?? proposal.ops, catalog: catalog, opLog: log,
                                                year: Calendar(identifier: .gregorian).component(.year, from: now),
                                                at: ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!))
            try requireRepaired(resolved, asked: proposal.raw["provenance"]?["repair"], on: catalog, actor: actor, now: now)
            return resolved.map { op in
                OpBody(op: op["op"]?.stringValue ?? "", args: op["args"]?.objectValue ?? JSONObject(), actor: actor,
                       extra: [("proposal", .string(proposal.id)), ("approved_by", .string(approvedBy))]
                           + (op["note"].map { [("note", $0)] } ?? []))
            }
        }
        let applied: [JSONObject]
        do {
            applied = try apply(building: bodies, batch: proposal.id, now: now)
        } catch let done as AlreadyApplied {
            var raw = proposal.raw
            raw.set("state", .str("applied"))
            raw.set("applied_ops", .array(done.lines.compactMap { $0["id"] }))
            try ProposalStore.save(Proposal(raw: raw), in: folder)
            return done.lines
        }
        var raw = proposal.raw
        raw.set("state", .str("applied"))
        raw.set("applied_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
        raw.set("applied_ops", .array(applied.compactMap { $0["id"] }))
        if edited != nil { raw.set("edited", .bool(true)) }   // for the filing-quality measure (mvp.md 1.2)
        try ProposalStore.save(Proposal(raw: raw), in: folder)
        return applied
    }

    /// The card's ops are in the log already: `approve` marks the card and returns them, applying nothing.
    struct AlreadyApplied: Error {
        let lines: [JSONObject]
    }

    /// A repair card (provenance `repair`: what it asks for, by field name or rule) is applied only when it leaves
    /// none of that missing on the items it changes, judged by the v0 rules adoption judged it by (binder-v0 §9.4
    /// step 4). Approved unchanged, it would otherwise count as done while the item still lacks what it asked for.
    func requireRepaired(_ ops: [JSONObject], asked: JSONValue?, on catalog: JSONObject, actor: JSONObject, now: Date) throws {
        let names = Set(asked?.arrayValue?.compactMap(\.stringValue) ?? [])
        guard !names.isEmpty else { return }
        let at = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)
        let lines: [JSONObject] = ops.map { op in
            var line = op
            line.set("id", .string(UUIDv7.make(now: now)))
            line.set("at", .string(at))
            line.set("actor", .object(actor))
            return line
        }
        let after = try TransactionGuard.check(lines, on: catalog).catalog
        let items = after["open_items"]?.arrayValue ?? []
        let ids = Set(ops.filter { $0["op"] == .str("update_item") }.compactMap { $0["args"]?["id"] })
        let left = ItemRules.check(items: items, log: after["processing_log"]?.arrayValue ?? [], v0: true).compactMap { f -> String? in
            guard let i = TransactionGuard.itemIndex(f.location), items.indices.contains(i), let id = items[i]["id"], ids.contains(id)
            else { return nil }
            let name = f.field ?? f.code.rawValue
            return names.contains(name) ? name : nil
        }
        if !left.isEmpty { throw Refused(reason: "fill in what is still missing: " + Array(Set(left)).sorted().joined(separator: ", ")) }
    }

    public func reject(_ proposal: Proposal, reason: String? = nil, now: Date = Date()) throws {
        var raw = proposal.raw
        raw.set("state", .str("rejected"))
        raw.set("rejected_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
        if let reason { raw.set("rejected_reason", .string(reason)) }
        try ProposalStore.save(Proposal(raw: raw), in: folder)
    }
}
