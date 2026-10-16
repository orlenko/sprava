import BinderFormat
import BinderStore
import Clerk
import Foundation
import Shelf
import SpravaKit

/// The settings commands: a binder's filing-list entry, and the doctor's findings.
extension Commands {
    static let settingsCommands: [String: Handler] = [
        "binder_settings": { c, _, r, now, today in try c.binderSettings(r, now: now, today: today) },
        "doctor": { c, _, r, now, today in try c.doctor(r, now: now, today: today) },
    ]

    /// The longest description the filing list keeps (`FilingList.set`).
    static let maxDescription = 160

    func binderSettings(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // The clerk's filing list: read, or set when description or filing is given (mvp.md feature 1).
        let f = try folder(r)
        let list = FilingList(support: support)
        // Until the person saves an entry, the binder is on the list unless it is at disclosure none (FilingList+Clerk).
        let teka = Teka.read(f)
        var entry = list.load()[f.path] ?? FilingList.defaultEntry(folder: f, teka: teka)
        if r["description"] != nil || r["filing"] != nil {
            if case .string(let d)? = r["description"] {
                // FilingList keeps one line of at most this many characters; a longer one is refused, never cut.
                guard d.trimmingCharacters(in: .whitespacesAndNewlines).count <= Self.maxDescription else {
                    throw Failure(message: "a binder's description is one line of at most \(Self.maxDescription) characters")
                }
                entry.description = d
            }
            if case .bool(let on)? = r["filing"] { entry.filing = on }
            // A private binder is offered by an opaque label, which means nothing without the person's own line
            // (architecture 5.4); any other binder can be offered by its name alone.
            if entry.filing, entry.description.trimmingCharacters(in: .whitespaces).isEmpty,
               PrivacyRatchet.disclosure(folder: f, teka: teka) == "none" {
                throw Failure(message: "This binder is private, so Sprava suggests it for notes only with a line you write about what it holds.")
            }
            try list.set(f, entry)
        }
        return JSONObject([(key: "description", value: .string(entry.description)), (key: "filing", value: .bool(entry.filing))])
    }

    func doctor(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // The same read the app's Health page makes in its own process while the runtime is stopped.
        let findings = try HealthSnapshot.doctorFindings(support: support, deviceID: deviceID)
        return JSONObject([(key: "findings", value: .array(findings.map {
            .obj([("level", .string($0.level.rawValue)), ("binder", $0.binder.map(JSONValue.string) ?? .null), ("text", .string($0.text))])
        }))])
    }
}
