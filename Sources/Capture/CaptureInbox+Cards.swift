import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

// The code-built Tier 0 card (architecture 5.2), and the words a card left unfiled.
extension CaptureInbox {
    /// The Tier 0 card: one item per non-empty line of the capture (at most 10), undated (`no_deadline`), filed into
    /// the physical binder explicitly selected in the app, or a non-private binder resolved from a verified
    /// hint. Both must be adopted and owned here. Otherwise keep it unfiled. Returns its id and destination.
    func card(for event: CaptureEvent, hint: String?, picked: URL? = nil, verified: Bool, producer: String, replaces: String?,
              binders: [ShelfRow], commands: Commands, now: Date) throws -> (String, URL?) {
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)),
                                (key: "model", value: .str("none"))])
        let allLines = Self.lines(of: event.text)
        let lines = allLines.prefix(10)
        var ops: [JSONObject] = []
        for (i, line) in lines.enumerated() {
            var item = JSONObject()
            item.set("id", .string("$new:\(i + 1)"))
            item.set("title", .string(String(line.text.prefix(200))))
            item.set("status", .str("open"))
            item.set("priority", .str("normal"))
            item.set("no_deadline", .bool(true))
            if event.isPrivate {
                item.set("redact", .bool(true))
                item.set("kind", .str("other"))
            }
            // The item keeps its line's span, so a correction of the note finds the item's own line (§6.5).
            item.set("provenance", .obj([("events", .array([.string(event.id)])), ("proposed_by", .object(actor)),
                                         ("span", .obj([("start", .int(line.start)), ("end", .int(line.end))]))]))
            let span = JSONValue.obj([("event", .string(event.id)), ("start", .int(line.start)), ("end", .int(line.end))])
            ops.append(JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .object(item))])),
                                   (key: "spans", value: .array([span]))]))
        }
        var provenance = JSONObject([(key: "events", value: .array([.string(event.id)])), (key: "producer", value: .string(producer)),
                                     (key: "filed_by", value: .str("code, no model"))])
        if !verified { provenance.set("unverified_source", .bool(true)) }
        if let replaces { provenance.set("supersedes", .string(replaces)) }
        // Lines past the tenth are kept as parts not filed yet, in the note's own words (architecture 5.2).
        if allLines.count > 10 {
            provenance.set("unfiled", .array(allLines.dropFirst(10).map { .obj([("start", .int($0.start)), ("end", .int($0.end)), ("reason", .str("more_lines"))]) }))
        }
        if event.isPrivate { provenance.set("private", .bool(true)) }
        let noun = event.raw["source"]?["kind"]?.stringValue == "dictation" ? "dictation" : "note"
        var title = lines.count == 1 ? "Add from a \(noun)" : "Add \(lines.count) items from a \(noun)"
        if replaces != nil { title = "Corrected \(noun): " + title.prefix(1).lowercased() + title.dropFirst() }
        let proposal = Proposal.make(title: title, actor: actor, ops: ops, provenance: provenance, now: now)

        // A binder whose writes are blocked until a repair (an op log that cannot be read counts as adopted) gets no
        // new card; the note waits in the Inbox, as the clerk's cards do.
        let destination = binders.first { row in
            guard row.teka.isAdopted, !row.teka.writesBlocked, Owner.device(of: row.folder) == commands.deviceID else { return false }
            if let picked { return row.folder.resolvingSymlinksInPath() == picked.resolvingSymlinksInPath() }
            return hint != nil && row.teka.name == hint && PrivacyRatchet.disclosure(row) != "none"
        }
        if let row = destination {
            do {
                try BinderWrite.save(proposal, in: row.folder, deviceID: commands.deviceID)
                do {
                    try commands.trustProposals([proposal.id], in: row.folder)
                } catch {
                    // The binder's copy could never be approved: it goes before the card waits in the Inbox instead.
                    BinderWrite.takeBackUntrusted(proposal, in: row.folder, deviceID: commands.deviceID, now: now)
                    throw error
                }
                return (proposal.id, row.folder)
            } catch {
                journal([("event", .string(event.id)), ("stage", .str("file_failed")), ("code", .string("\(type(of: error))"))])
            }
        }
        var raw = proposal.raw
        raw.set("binder", .str("not sure"))
        try writeUnfiled(raw)
        return (proposal.id, nil)
    }

    /// The words of the spans a card lists as not filed yet, read from the capture itself.
    public func notFiled(_ proposal: Proposal) -> [String] {
        guard let spans = proposal.raw["provenance"]?["unfiled"]?.arrayValue, !spans.isEmpty,
              let id = proposal.raw["provenance"]?["events"]?.arrayValue?.first?.stringValue,
              let text = storedText(id, paths: loadState().paths ?? [:]) else { return [] }
        let scalars = Array(text.unicodeScalars)
        return spans.compactMap { span in
            guard let a = span["start"]?.numberValue?.safeInteger, let b = span["end"]?.numberValue?.safeInteger,
                  a >= 0, a < b, Int(b) <= scalars.count else { return nil }
            var v = String.UnicodeScalarView()
            v.append(contentsOf: scalars[Int(a)..<Int(b)])
            return String(v)
        }
    }
}
