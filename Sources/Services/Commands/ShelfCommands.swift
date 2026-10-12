import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

/// The Shelf's commands: the app picks a folder or takes one off the Shelf, and the runtime writes `shelf.json`
/// (architecture 2.3). Sprava's own state only, never a binder.
extension Commands {
    static let shelfCommands: [String: Handler] = [
        "shelf_add": { c, _, r, _, _ in try c.shelfAdd(r) },
        "shelf_remove": { c, _, r, _, _ in try c.shelfRemove(r) },
    ]

    func shelfAdd(_ r: JSONObject) throws -> JSONObject {
        let f = try folder(r)
        let teka = Teka.read(f)
        guard teka.state != .notATeka else { throw Failure(message: "\(f.lastPathComponent) has no catalog.json, so it is not a binder") }
        try ShelfStore(supportDirectory: support).add(f)
        return JSONObject([(key: "name", value: .string(teka.name)), (key: "state", value: .string(teka.state.label))])
    }

    func shelfRemove(_ r: JSONObject) throws -> JSONObject {
        try ShelfStore(supportDirectory: support).remove(try folder(r))
        return JSONObject()
    }
}
