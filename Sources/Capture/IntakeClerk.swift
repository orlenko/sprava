import BinderStore
import Clerk
import Foundation
import SpravaKit

/// The clerk's side of intake (docs/adaptation-layer.md §4.2 to §4.4): the next reading to read, and its card.
extension IntakeWatcher {
    /// The oldest reading waiting for the clerk whose card is still waiting for the person. The attempt is
    /// recorded before any model call: two unfinished attempts and the file keeps its code-built card.
    public func nextForReading() -> IntakeReadings.Entry? {
        let store = IntakeReadings(support: support)
        for var e in store.all().filter({ $0.state == "pending" || $0.state == "attempt" }).sorted(by: { $0.createdAt < $1.createdAt }) {
            let folder = URL(fileURLWithPath: e.binder, isDirectory: true)
            guard ProposalStore.list(in: folder).contains(where: { $0.0.id == e.card && $0.0.state == "proposed" }) else {
                e.state = "kept"
                try? store.save(e)
                continue
            }
            if e.attempts >= 2 {
                e.state = "kept"
                try? store.save(e)
                continue
            }
            e.attempts += 1
            e.state = "attempt"
            // The attempt is on disk before any model call, or there is no call this run (the poison rule).
            guard (try? store.save(e)) != nil else { return nil }
            return e
        }
        return nil
    }

    public struct ReadingOutcome: Equatable, Sendable {
        public var items = 0
        public var replaced = false
        public var escalated = false
        /// The code-built card was changed by another program since Sprava wrote it: nothing was built on it.
        public var cardChanged = false
    }

    /// Stores the clerk's card for a document and withdraws the code-built one, unless the person acted on it
    /// meanwhile. A reading that found nothing more than code did leaves the code-built card, with the reading
    /// added to it.
    public func commitReading(_ entry: IntakeReadings.Entry, _ doc: DocumentReading, commands: Commands, now: Date = Date()) -> ReadingOutcome {
        var outcome = ReadingOutcome()
        let store = IntakeReadings(support: support)
        guard var e = store.load(entry.id), e.state == "attempt" else { return outcome }
        let loaded = e
        let folder = URL(fileURLWithPath: e.binder, isDirectory: true)
        // The clerk's card is built on the code-built card's ops, so only a card still as Sprava wrote it is used;
        // one another program changed stays as it is, unverified, and is never carried into a trusted card.
        let tier0: Proposal
        do { tier0 = try commands.loadTrusted(e.card, in: folder) } catch {
            outcome.cardChanged = error is ProposalStore.Tampered
            e.state = "kept"
            try? store.save(e)
            return outcome
        }
        guard tier0.state == "proposed" else {
            e.state = "kept"
            try? store.save(e)
            return outcome
        }
        e.result = doc.json
        e.escalate = doc.escalate
        e.escalation = doc.escalate.isEmpty ? nil : "waiting"
        outcome.escalated = !doc.escalate.isEmpty

        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)),
                                (key: "model", value: .string(doc.model))])
        // The filing ops, with the clerk's title and date for the main document when code had none better.
        var ops = tier0.ops
        if var args = ops.first?["args"]?.objectValue, var document = args["document"]?.objectValue {
            if let title = doc.title, e.reading.subject == nil { document.set("title", .string(title)) }
            if document["date"] == nil, let d = doc.date { document.set("date", .string(d.description)) }
            if document["kind"] == nil, doc.documentClass != "unsure" { document.set("kind", .string(doc.documentClass == "governing" ? "governing" : doc.documentClass == "action" ? "notice" : "record")) }
            args.set("document", .object(document))
            ops[0].set("args", .object(args))
        }
        let event = CaptureEvent(raw: JSONObject([(key: "id", value: .string(e.id)), (key: "sensitivity", value: .str("unmarked")),
                                                  (key: "source", value: .obj([("app", .str("sprava.intake")), ("kind", .string(e.reading.kind))]))]),
                                 url: URL(fileURLWithPath: "/dev/null"), digest: "")
        let interp = Interpretation(id: doc.id, event: e.id, model: doc.model)
        let today = CalendarDate.today(now: now)
        let built = Clerk.itemOps(doc.items, event: event.clerkInput, today: today, actor: actor, interp: interp, now: now, firstNumber: ops.count + 1)
        ops += built.ops
        outcome.items = built.ops.count

        var provenance = tier0.raw["provenance"]?.objectValue ?? JSONObject()
        provenance.set("reading", .object(doc.json))
        if !doc.escalate.isEmpty { provenance.set("escalate", .array(doc.escalate.map(JSONValue.string))) }
        if !built.already.isEmpty { provenance.set("already_in_binder", .array(built.already.map(JSONValue.string))) }
        if !built.rejected.isEmpty { provenance.set("left_out", .array(built.rejected.map(JSONValue.string))) }
        provenance.set("filed_by", .str("clerk"))
        // The card it replaces, so a scan can finish a replacement a crash cut short.
        provenance.set("replaces", .string(tier0.id))
        let shown = ops.first?["args"]?["document"]?["title"]?.stringValue ?? e.name
        let title = built.ops.isEmpty ? "File \u{201C}\(shown)\u{201D}"
            : "File \u{201C}\(shown)\u{201D} and add \(built.ops.count) item\(built.ops.count == 1 ? "" : "s")"
        let proposal = Proposal.make(title: title, actor: actor, ops: ops, provenance: provenance, now: now)
        // A card an earlier commit made before it was cut short is never followed by anything: it goes.
        for (p, _) in ProposalStore.list(in: folder) where p.state == "proposed" && p.raw["provenance"]?["replaces"] == .string(tier0.id) {
            try? TekaStore(folder: folder).reject(p, reason: "replaced by the clerk's reading", now: now)
        }
        do {
            try ProposalStore.save(proposal, in: folder)
            try commands.trustProposals([proposal.id], in: folder)
        } catch {
            e.state = "kept"
            try? store.save(e)
            return outcome
        }
        // The reading names the new card, then the watcher follows it, so a file that changes or goes withdraws it;
        // only then does the code-built card go. When either cannot be written, the new card is taken back and the
        // reading is tried again; a crash in between is finished by the next scan (`finishReplacement`).
        e.card = proposal.id
        e.state = "read"
        guard (try? store.save(e)) != nil, follow(e.name, in: folder, from: tier0.id, to: proposal.id) else {
            try? TekaStore(folder: folder).reject(proposal, reason: "the intake cursor could not follow it", now: now)
            var back = loaded
            back.state = loaded.attempts >= 2 ? "kept" : "pending"
            try? store.save(back)
            return ReadingOutcome()
        }
        try? TekaStore(folder: folder).reject(tier0, reason: "replaced by the clerk's reading", now: now)
        outcome.replaced = true
        return outcome
    }

    /// Points the cursor's entry for `name` from the code-built card to its replacement. False when the cursor
    /// cannot be read or written, or no longer follows the code-built card (the file changed or went).
    func follow(_ name: String, in folder: URL, from old: String, to new: String) -> Bool {
        let key = folder.standardizedFileURL.path
        guard var state = try? load(), var seen = state[key], var s = seen[name], s.card == old else { return false }
        s.card = new
        seen[name] = s
        state[key] = seen
        return (try? save(state)) != nil
    }

    /// The model failed on this reading: it is tried once more on the next run, then the code-built card stays.
    public func failReading(_ entry: IntakeReadings.Entry) {
        let store = IntakeReadings(support: support)
        guard var e = store.load(entry.id), e.state == "attempt" else { return }
        e.state = e.attempts >= 2 ? "kept" : "pending"
        try? store.save(e)
    }
}
