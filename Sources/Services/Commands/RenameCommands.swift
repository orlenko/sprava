import BinderFormat
import BinderStore
import Foundation
import Hub
import SpravaKit

/// The person's rename (binder-v0 §3.1, §6.3): after a binder's folder was renamed or copied, its catalog still holds
/// the old name. The binder then publishes and drains nothing and is offered no stamp. Only the person can say which
/// of the two happened, and what becomes of the old name follows from it.
extension Commands {
    static let renameCommands: [String: Handler] = [
        "use_folder_name": { c, _, r, now, today in try c.useFolderName(r, now: now, today: today) },
    ]

    /// How long a renamed binder still drains what was addressed to its old name (binder-v0 §6.3).
    static let formerNameDays = 30

    /// `use_folder_name`: `{binder, former}`. Applies `rename_teka` as the person's own action, setting the binder's
    /// name to its folder's. `former` says whose the old name is:
    /// - `renamed`: this binder's, under a new name. It keeps the old name for `formerNameDays`, so what was addressed
    ///   to it is still drained;
    /// - `copy`: another binder's, which still uses it. The old name ends yesterday, so this binder never drains,
    ///   withdraws or blocks what belongs to the original. Refused for a binder that already holds a name's history
    ///   on the hub (`HubLane.holdsHubHistory`): it would act for the original through what it inherited.
    /// Then offers the stamp, which the differing name held back. Returns `{op, stamp?}`, or `stamp_error` when the
    /// rename stands and the stamp could not be offered yet.
    func useFolderName(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let f = try folder(r)
        let teka = Teka.read(f)
        guard teka.isAdopted else { throw Failure(message: "adopt this binder first; its name is settled after that") }
        guard teka.nameDiffersFromFolder, case .string(let former)? = teka.catalog?["meta"]?["name"] else {
            throw Failure(message: "this binder's name already is its folder's name")
        }
        let until: CalendarDate
        switch r["former"]?.stringValue {
        case "renamed": until = today.adding(days: Self.formerNameDays)
        case "copy":
            // A copy of a binder that already shared under a name carries that binder's claims with it: former names
            // it would drain, and the record of a slice it would remove. Giving those up safely is not built, so
            // such a binder is not made a copy here.
            guard !HubLane.holdsHubHistory(teka, today: today) else {
                throw Failure(message: "This binder has shared its to-dos under a name before, so Sprava cannot yet make it an independent copy. "
                    + "If it is the same binder under a new folder name, choose \u{201C}It was renamed\u{201D}.")
            }
            until = today.adding(days: -1)
        default: throw Failure(message: "use_folder_name needs former: renamed or copy")
        }
        let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
        let args = JSONObject([(key: "name", value: .string(f.lastPathComponent)), (key: "former", value: .string(former)),
                               (key: "until", value: .string(until.description))])
        let applied = try TekaStore(folder: f, client: client).apply([.init(op: "rename_teka", args: args, actor: actor)], now: now)
        var reply = JSONObject([(key: "op", value: applied.first?["id"] ?? .null)])
        // The rename stands either way; a stamp that could not be offered is offered again when the cards are listed.
        do {
            _ = try reviewableCards(in: f, catalog: Teka.read(f).catalog)
            if let stamp = try Adoption.offerStamp(f, client: client, now: now) {
                try recordDigests([stamp], in: f)
                reply.set("stamp", .string(stamp))
            }
        } catch {
            reply.set("stamp_error", .string("the binder's stamp could not be offered yet (\(error)); it is offered again when its cards are next opened"))
        }
        return reply
    }
}
