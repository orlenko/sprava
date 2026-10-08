import BinderStore
import Capture
import Foundation
import SpravaKit

/// The capture commands: the app's notices, the Inbox's unfiled cards, and the intake readings waiting for a careful reading.
extension Commands {
    static let captureCommands: [String: Handler] = [
        "capture_notice": { c, _, r, now, today in try c.captureNotice(r, now: now, today: today) },
        "unfiled": { c, _, r, now, today in try c.unfiled(r, now: now, today: today) },
        "file_card": { c, _, r, now, today in try c.fileCard(r, now: now, today: today) },
        "discard_card": { c, _, r, now, today in try c.discardCard(r, now: now, today: today) },
        "readings": { c, _, r, now, today in try c.readings(r, now: now, today: today) },
        "dismiss_reading": { c, _, r, now, today in try c.dismissReading(r, now: now, today: today) },
    ]

    func captureNotice(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // The app tells the runtime it wrote this event (architecture 8).
        guard case .string(let event)? = r["event"], case .string(let digest)? = r["sha256"] else {
            throw Failure(message: "capture_notice needs event and sha256")
        }
        try inbox.recordNotice(event: event, digest: digest, now: now)
        return JSONObject()
    }

    func unfiled(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        return JSONObject([(key: "cards", value: .array(inbox.unfiled().map { p in
            var o = JSONObject()
            o.set("id", .string(p.id))
            o.set("title", .string(p.title))
            o.set("created_at", p.raw["created_at"] ?? .null)
            o.set("lines", .array(p.ops.map { .string(Proposal.describe($0, catalog: nil)) }))
            o.set("notes", .array(p.cardNotes.map(JSONValue.string)))
            o.set("not_filed", .array(inbox.notFiled(p).map(JSONValue.string)))
            for flag in ["source_retracted", "source_corrected"] where p.raw[flag] == .bool(true) { o.set(flag, .bool(true)) }
            if let prov = p.raw["provenance"]?.objectValue {
                o.set("unverified_source", .bool(prov["unverified_source"] == .bool(true)))
                o.set("private", .bool(prov["private"] == .bool(true)))
                o.set("producer", prov["producer"] ?? .null)
            }
            return .object(o)
        }))])
    }

    func fileCard(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        guard case .string(let id)? = r["card"] else { throw Failure(message: "file_card needs card") }
        try inbox.file(id, into: try folder(r), commands: self)
        return JSONObject()
    }

    func discardCard(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        guard case .string(let id)? = r["card"] else { throw Failure(message: "discard_card needs card") }
        try inbox.discard(id)
        return JSONObject()
    }

    func readings(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // Intake documents and the clerk's reading of them, for the app's careful-reading list.
        let readings = IntakeReadings(support: support).escalations()
        return JSONObject([(key: "readings", value: .array(readings.map { e in
            .obj([("id", .string(e.id)), ("binder", .string(e.binder)), ("name", .string(e.name)), ("card", .string(e.card)),
                  ("title", e.result?["title"] ?? .string(e.reading.subject ?? e.name)), ("class", e.result?["class"] ?? .null),
                  ("summary", e.result?["summary"] ?? .null), ("reasons", .array(e.escalate.map(JSONValue.string)))])
        }))])
    }

    func dismissReading(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        guard case .string(let id)? = r["reading"] else { throw Failure(message: "dismiss_reading needs reading") }
        let store = IntakeReadings(support: support)
        guard var e = store.load(id) else { throw Failure(message: "no such reading") }
        e.escalation = "dismissed"
        try store.save(e)
        return JSONObject()
    }
}
