import BinderStore
import Foundation
import Shelf
import SpravaKit

/// The settings commands: a binder's filing-list entry, and the doctor's findings.
extension Commands {
    static let settingsCommands: [String: Handler] = [
        "binder_settings": { c, _, r, now, today in try c.binderSettings(r, now: now, today: today) },
    ]

    /// The longest description the filing list keeps (`FilingList.set`).
    static let maxDescription = 160

    func binderSettings(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // The clerk's filing list: read, or set when description or filing is given (mvp.md feature 1).
        let f = try folder(r)
        let list = FilingList(support: support)
        var entry = list.load()[f.path] ?? FilingList.Entry(description: FilingList.readmeLine(f) ?? "", filing: false)
        if r["description"] != nil || r["filing"] != nil {
            if case .string(let d)? = r["description"] {
                // FilingList keeps one line of at most this many characters; a longer one is refused, never cut.
                guard d.trimmingCharacters(in: .whitespacesAndNewlines).count <= Self.maxDescription else {
                    throw Failure(message: "a binder's description is one line of at most \(Self.maxDescription) characters")
                }
                entry.description = d
            }
            if case .bool(let on)? = r["filing"] { entry.filing = on }
            if entry.filing, entry.description.trimmingCharacters(in: .whitespaces).isEmpty {
                throw Failure(message: "a binder on the filing list needs a one-line description")
            }
            try list.set(f, entry)
        }
        return JSONObject([(key: "description", value: .string(entry.description)), (key: "filing", value: .bool(entry.filing))])
    }
}
