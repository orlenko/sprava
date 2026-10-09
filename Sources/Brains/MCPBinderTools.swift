import BinderFormat
import BinderStore
import Capture
import CryptoKit
import Darwin
import Foundation
import Shelf
import SpravaKit

/// Which binders a client sees, and the read-only binder tools: list_binders and get_proposal (architecture 7.3, 7.6).
extension MCPServer {
    /// The binders this client may see: in its scope, not blocked from federation, and not at disclosure `none` as
    /// last confirmed by the person (architecture 7.6; the privacy ratchet, 4.5). A federation-blocked binder (a
    /// stamped catalog without a valid `meta.disclosure`, a name that differs from its folder, writes blocked) has
    /// no level that says what may leave it, so nothing does: the hub withdraws its slice, and a brain sees nothing
    /// of it either. An absent disclosure would otherwise read as `full`.
    package func visible() -> [(ShelfRow, String)] {
        shelf().compactMap { row in
            guard row.teka.isAdopted, !row.teka.federationBlocked, let level = client.level(for: row.folder),
                  PrivacyRatchet.disclosure(row) != "none" else { return nil }
            return (row, level)
        }
    }

    /// A name compared as binder-v0 §3.1 compares binder names: after NFC and case folding.
    static func fold(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil) }

    /// The binder a call names. A name two visible binders share is no binder: a change must never land in the
    /// wrong one (`missing` says why).
    func binder(_ args: JSONObject) -> (ShelfRow, String)? {
        guard case .string(let name)? = args["binder"] else { return nil }
        let matches = visible().filter { Self.fold($0.0.teka.name) == Self.fold(name) }
        guard matches.count == 1 else { return nil }
        return matches.first { $0.0.teka.name == name }
    }

    /// The error for a call whose binder was not found.
    func missing(_ args: JSONObject) -> JSONValue {
        guard case .string(let name)? = args["binder"], visible().filter({ Self.fold($0.0.teka.name) == Self.fold(name) }).count > 1 else {
            return Self.toolError("not found")
        }
        return Self.toolError("two binders share this name; ask the person to rename one in Sprava")
    }

    func listBinders() -> JSONValue {
        let today = CalendarDate.today(now: now())
        return Self.toolResult(.obj([("binders", .array(visible().map { row, level in
            let page = row.teka.nowPage(today: today)
            // Open as the Now page counts it: not closed, not dismissed.
            let open = row.teka.items.filter { $0.declaredStatus != .done && !$0.isDismissed }.count
            return .obj([("binder", .string(row.teka.name)), ("level", .string(level)),
                         ("open", .int(open)), ("overdue", .int(page.count(.overdue))),
                         ("waiting", .int(page.count(.waiting) + page.count(.nudge)))])
        }))]))
    }

    func getProposal(_ args: JSONObject) -> JSONValue {
        // A handle is a name, never a capability: it must belong to this client (architecture 7.3).
        guard let (row, _) = binder(args) else { return missing(args) }
        guard case .string(let pid)? = args["proposal_id"],
              let (p, _) = ProposalStore.list(in: row.folder).first(where: { $0.0.id == pid }),
              p.actor["kind"] == .str("brain"), p.actor["model"]?.stringValue == client.id else { return Self.toolError("not found") }
        return Self.toolResult(.obj([("proposal_id", .string(p.id)), ("state", .string(p.state)),
                                     ("applied_ops", p.raw["applied_ops"] ?? .array([]))]))
    }
}
