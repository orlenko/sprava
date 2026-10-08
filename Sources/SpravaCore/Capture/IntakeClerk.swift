import Foundation

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
                store.save(e)
                continue
            }
            if e.attempts >= 2 {
                e.state = "kept"
                store.save(e)
                continue
            }
            e.attempts += 1
            e.state = "attempt"
            store.save(e)
            return e
        }
        return nil
    }

    public struct ReadingOutcome: Equatable, Sendable {
        public var items = 0
        public var replaced = false
        public var escalated = false
    }

    /// Stores the clerk's card for a document and withdraws the code-built one, unless the person acted on it
    /// meanwhile. A reading that found nothing more than code did leaves the code-built card, with the reading
    /// added to it.
    public func commitReading(_ entry: IntakeReadings.Entry, _ doc: DocumentReading, commands: Commands, now: Date = Date()) -> ReadingOutcome {
        var outcome = ReadingOutcome()
        let store = IntakeReadings(support: support)
        guard var e = store.load(entry.id), e.state == "attempt" else { return outcome }
        let folder = URL(fileURLWithPath: e.binder, isDirectory: true)
        guard let (tier0, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == e.card }), tier0.state == "proposed" else {
            e.state = "kept"
            store.save(e)
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
        let built = Clerk.itemOps(doc.items, event: event, today: today, actor: actor, interp: interp, now: now, firstNumber: ops.count + 1)
        ops += built.ops
        outcome.items = built.ops.count

        var provenance = tier0.raw["provenance"]?.objectValue ?? JSONObject()
        provenance.set("reading", .object(doc.json))
        if !doc.escalate.isEmpty { provenance.set("escalate", .array(doc.escalate.map(JSONValue.string))) }
        if !built.already.isEmpty { provenance.set("already_in_binder", .array(built.already.map(JSONValue.string))) }
        if !built.rejected.isEmpty { provenance.set("left_out", .array(built.rejected.map(JSONValue.string))) }
        provenance.set("filed_by", .str("clerk"))
        let shown = ops.first?["args"]?["document"]?["title"]?.stringValue ?? e.name
        let title = built.ops.isEmpty ? "File \u{201C}\(shown)\u{201D}"
            : "File \u{201C}\(shown)\u{201D} and add \(built.ops.count) item\(built.ops.count == 1 ? "" : "s")"
        let proposal = Proposal.make(title: title, actor: actor, ops: ops, provenance: provenance, now: now)
        do {
            try ProposalStore.save(proposal, in: folder)
            try commands.trustProposals([proposal.id], in: folder)
        } catch {
            e.state = "kept"
            store.save(e)
            return outcome
        }
        try? TekaStore(folder: folder).reject(tier0, reason: "replaced by the clerk's reading", now: now)
        // The watcher follows the new card, so a file that changes or goes withdraws it. A cursor that cannot be
        // read is left as it is; the intake job reports it.
        let key = folder.standardizedFileURL.path
        if var state = try? load(), var seen = state[key], var s = seen[e.name], s.card == tier0.id {
            s.card = proposal.id
            seen[e.name] = s
            state[key] = seen
            try? save(state)
        }
        e.card = proposal.id
        e.state = "read"
        store.save(e)
        outcome.replaced = true
        return outcome
    }

    /// The model failed on this reading: it is tried once more on the next run, then the code-built card stays.
    public func failReading(_ entry: IntakeReadings.Entry) {
        let store = IntakeReadings(support: support)
        guard var e = store.load(entry.id), e.state == "attempt" else { return }
        e.state = e.attempts >= 2 ? "kept" : "pending"
        store.save(e)
    }
}
