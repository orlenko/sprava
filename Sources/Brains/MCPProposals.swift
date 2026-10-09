import BinderFormat
import BinderStore
import Capture
import CryptoKit
import Darwin
import Foundation
import Shelf
import SpravaKit

/// propose_ops: what a brain may send, and how a card it proposes is stored and trusted (architecture 4.6, 7.3).
extension MCPServer {
    /// Why a string a brain sent cannot be stored, or nil. Control characters (tabs and line breaks aside, and
    /// none at all in a title), format characters such as bidirectional overrides, zero-width and TAG characters,
    /// line and paragraph separators, and other default-ignorable code points are refused, so the person reads on
    /// the card exactly what would be stored (architecture 4.2 step 6). The guard's own sanitizer, for every actor,
    /// is still to come.
    static func unsafeText(_ text: String, title: Bool = false) -> String? {
        for s in text.unicodeScalars {
            let p = s.properties
            switch p.generalCategory {
            case .control where title || !["\n", "\t"].contains(s): return "a control character"
            case .format, .lineSeparator, .paragraphSeparator: return "an invisible or direction-changing character (U+\(String(s.value, radix: 16, uppercase: true)))"
            default: if p.isDefaultIgnorableCodePoint { return "an invisible character (U+\(String(s.value, radix: 16, uppercase: true)))" }
            }
        }
        return nil
    }

    /// The first unsafe string anywhere in `value`, with where it was found.
    static func unsafeText(in value: JSONValue, at path: String) -> String? {
        switch value {
        case .string(let s): return unsafeText(s).map { "\(path) holds \($0)" }
        case .array(let a): return a.enumerated().lazy.compactMap { unsafeText(in: $1, at: "\(path)[\($0)]") }.first
        case .object(let o): return o.entries.lazy.compactMap { e in unsafeText(e.key).map { "\(path) has a key with \($0)" } ?? unsafeText(in: e.value, at: "\(path).\(e.key)") }.first
        default: return nil
        }
    }

    /// Whether Sprava recorded this proposal's digest, which approval requires (architecture 4.6).
    func isRecorded(_ id: String, in folder: URL) -> Bool { (try? commands.loadDigests())?[commands.key(folder, id)] != nil }

    struct Uninspectable: Error {}

    /// This client's card for a request id, or nil. Unlike `ProposalStore.list`, which skips what it cannot read, a
    /// card file that cannot be read or parsed throws: it may be this very request's card, and a second card for the
    /// same request would leave two to approve once the first is readable again. Each card is read with
    /// `SafeFile.read`: never through a link, never blocking on a FIFO (this runs on the command queue the person's
    /// approvals share), only a plain file of this user. A card file that is refused or cannot be read just now
    /// makes the folder uninspectable; a file gone since the listing is no card.
    static func card(for requestID: String, client: String, in folder: URL) throws -> Proposal? {
        var st = stat()
        if lstat(ProposalStore.dir(folder).path, &st) != 0, errno == ENOENT { return nil }   // no card was ever stored
        let dir = try ProposalStore.checkedDir(folder, create: false)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        where name.hasSuffix(".json") && ProposalStore.isValidID(String(name.dropLast(5))) {
            let data: Data
            switch SafeFile.read(dir.appendingPathComponent(name)) {
            case .ok(let d): data = d
            case .missing: continue
            case .refused, .unreadable: throw Uninspectable()
            }
            guard case .object(let o) = try JSONParser.parse(data).value, o["id"]?.stringValue == String(name.dropLast(5)) else {
                throw Uninspectable()
            }
            let p = Proposal(raw: o)
            if p.actor["kind"] == .str("brain"), p.actor["model"]?.stringValue == client, p.raw["request_id"]?.stringValue == requestID {
                return p
            }
        }
        return nil
    }

    func proposeOps(_ args: JSONObject) -> JSONValue {
        guard let (row, level) = binder(args) else { return missing(args) }
        guard level == "propose" else { return Self.toolError("this client may only read this binder") }
        guard Owner.device(of: row.folder) == commands.deviceID else {
            return Self.toolError("this binder is managed by another Sprava; it is read-only here")
        }
        guard case .string(let title)? = args["title"], !title.isEmpty, case .array(let ops)? = args["ops"], !ops.isEmpty else {
            return Self.toolError("title and ops are required")
        }
        // Checked before any per-op work, which runs on the command queue the person's approvals share.
        guard ops.count <= Self.maxOps else { return Self.toolError("at most \(Self.maxOps) ops per proposal") }
        var bodies: [JSONObject] = []
        guard ops.allSatisfy({ $0.objectValue != nil }) else { return Self.toolError("each op is an object with op and args") }
        for case .object(let op) in ops {
            guard case .string(let type)? = op["op"], Self.proposable.contains(type) else {
                return Self.toolError("op must be one of \(Self.proposable.sorted().joined(separator: ", "))")
            }
            if type == "add_item", op["args"]?["item"]?["id"]?.stringValue?.hasPrefix("$new:") != true {
                return Self.toolError("new items use placeholder ids such as $new:1; ids are minted on approval")
            }
            if type == "file_document" {
                // Only the intake form for now: the file is already in the binder, named by its digest.
                let doc = op["args"]?["document"]
                guard doc?["id"]?.stringValue?.hasPrefix("$new:") == true else {
                    return Self.toolError("file_document: the document id is a placeholder such as $new:1; ids are minted on approval")
                }
                guard op["args"]?["content"] == nil, doc?["content"] == nil else {
                    return Self.toolError("file_document: a document written by a brain is not accepted yet; file a file from intake/")
                }
                guard case .string(let from)? = op["args"]?["from"], DocumentPaths.isIntake(from) else {
                    return Self.toolError("file_document: from must name a file in the binder's intake/")
                }
            }
            var body = JSONObject([(key: "op", value: .string(type)), (key: "args", value: op["args"] ?? .obj([]))])
            if let note = op["note"] { body.set("note", note) }
            bodies.append(body)
        }
        if let problem = Self.unsafeText(title, title: true) { return Self.toolError("title holds \(problem)") }
        if let r = args["rationale"], let problem = Self.unsafeText(in: r, at: "rationale") { return Self.toolError(problem) }
        for (i, body) in bodies.enumerated() {
            if let problem = Self.unsafeText(in: .object(body), at: "ops[\(i)]") { return Self.toolError(problem) }
        }
        if Proposal.hasDuplicatePlaceholders(bodies) { return Self.toolError("each new record needs its own placeholder name") }
        let requestID = args["request_id"]?.stringValue
        // A retry after a lost reply. Nothing in the stored file is believed unless Sprava recorded its digest.
        var replacing: String?
        if let requestID {
            let found: Proposal?
            do { found = try Self.card(for: requestID, client: client.id, in: row.folder) } catch {
                return Self.toolError("the binder's proposals cannot all be read, so this request_id cannot be checked; try again later")
            }
            if let found {
                guard let digests = try? commands.loadDigests() else {
                    return Self.toolError("Sprava's record of the cards it wrote cannot be read; try again later")
                }
                if [row.folder, row.folder.standardizedFileURL].contains(where: { digests[commands.key($0, found.id)] != nil }) {
                    // Recorded: only the card exactly as Sprava wrote it, and still this request's, is answered from.
                    guard let p = try? commands.loadTrusted(found.id, in: row.folder), p.actor["model"]?.stringValue == client.id,
                          p.raw["request_id"]?.stringValue == requestID else {
                        return Self.toolError("the proposal with this request_id was changed outside Sprava; use a new request_id")
                    }
                    // The reading the card answers may still be waiting (its update failed, or the runtime stopped
                    // before it): finish it now, so no other brain takes it up again.
                    if let id = p.raw["provenance"]?["reading"]?.stringValue, let problem = markAnswered(id, by: p.id, in: row, retryable: true) {
                        return problem
                    }
                    return Self.toolResult(.obj([("proposal_id", .string(p.id)), ("state", .string(p.state))]))
                }
                // Never recorded (the runtime stopped between storing and recording it): the file is not believed at
                // all. The card this request makes replaces it under the same id, checked like any new one.
                replacing = found.id
            }
        }
        for body in bodies where body["op"] == .str("file_document") {
            let args = body["args"]
            guard let from = args?["from"]?.stringValue, let sha = queuedIntakeDigest(from, in: row.folder),
                  args?["document"]?["sha256"]?.stringValue == sha else {
                return Self.toolError("file_document: \(args?["from"]?.stringValue ?? "from") is not in intake/, or sha256 is not its digest"
                                      + " (a file over \(Self.intakeSizeLimit >> 20) MiB is filed in the Sprava app)")
            }
        }
        let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .string(commands.client)),
                                (key: "model", value: .string(client.id))])
        // Validated at once against the catalog, so the model can correct itself.
        do {
            try TekaStore.dryRun(bodies, actor: actor, folder: row.folder, now: now())
        } catch {
            return Self.toolError("the batch would not be accepted: \(error)")
        }
        var provenance = JSONObject([(key: "client", value: .string(client.id))])
        if let r = args["rationale"] { provenance.set("rationale", r) }
        let answered = args["reading_id"] == nil ? nil : reading(args, in: row)
        if args["reading_id"] != nil, answered == nil { return Self.toolError("reading_id: not found") }
        if let answered { provenance.set("reading", .string(answered.id)) }
        var proposal = Proposal.make(title: title, actor: actor, ops: bodies, provenance: provenance, now: now())
        if let requestID { proposal.raw.set("request_id", .string(requestID)) }
        if let replacing { proposal.raw.set("id", .string(replacing)) }
        do {
            try ProposalStore.save(proposal, in: row.folder)
            try commands.trustProposals([proposal.id], in: row.folder)
        } catch {
            return Self.toolError("could not store the proposal")
        }
        // An unrecorded card could never be approved: say so rather than "proposed".
        guard isRecorded(proposal.id, in: row.folder) else {
            return Self.toolError("the proposal was stored but could not be recorded as written by Sprava; send the same request again")
        }
        if let answered, let problem = markAnswered(answered.id, by: proposal.id, in: row, retryable: requestID != nil) {
            return problem
        }
        return Self.toolResult(.obj([("proposal_id", .string(proposal.id)), ("state", .str("proposed")),
                                     ("note", .str("Waiting for the person in the Sprava app. Nothing has changed yet."))]))
    }
}
