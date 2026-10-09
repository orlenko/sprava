import BinderStore
import Foundation
import Shelf
import SpravaKit

/// The settings commands: a binder's filing-list entry, and the doctor's findings.
extension Commands {
    static let settingsCommands: [String: Handler] = [
        "binder_settings": { c, _, r, now, today in try c.binderSettings(r, now: now, today: today) },
        "doctor": { c, _, r, now, today in try c.doctor(r, now: now, today: today) },
    ]

    func binderSettings(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // The clerk's filing list: read, or set when description or filing is given (mvp.md feature 1).
        let f = try folder(r)
        let list = FilingList(support: support)
        var entry = list.load()[f.path] ?? FilingList.Entry(description: FilingList.readmeLine(f) ?? "", filing: false)
        if r["description"] != nil || r["filing"] != nil {
            if case .string(let d)? = r["description"] { entry.description = d }
            if case .bool(let on)? = r["filing"] { entry.filing = on }
            if entry.filing, entry.description.trimmingCharacters(in: .whitespaces).isEmpty {
                throw Failure(message: "a binder on the filing list needs a one-line description")
            }
            try list.set(f, entry)
        }
        // An adoption cut short leaves Adoption's marker (`.sprava/adoption-unfinished`, a plain file); running the
        // adopt command again finishes it, so the app offers that.
        var marker = stat()
        let unfinished = lstat(f.appendingPathComponent(".sprava/adoption-unfinished").path, &marker) == 0
            && marker.st_mode & S_IFMT == S_IFREG
        return JSONObject([(key: "description", value: .string(entry.description)), (key: "filing", value: .bool(entry.filing)),
                           (key: "adoption_unfinished", value: .bool(unfinished))])
    }

    func doctor(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // The same read the app's Health page makes in its own process while the runtime is stopped.
        let findings = try HealthSnapshot.doctorFindings(support: support, deviceID: deviceID)
        return JSONObject([(key: "findings", value: .array(findings.map {
            .obj([("level", .string($0.level.rawValue)), ("binder", $0.binder.map(JSONValue.string) ?? .null), ("text", .string($0.text))])
        }))])
    }
}
