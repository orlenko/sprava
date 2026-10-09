@testable import BinderStore
import BinderFormat
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Every loosening binder-v0 §5.5 names, arriving by an outside edit, is held back until the person approves the
/// privacy card, and stands once approved. Invented data only.
@Suite struct PrivacyRatchetTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])

    struct Case {
        let name: String
        /// The disclosure the person confirmed before the edit.
        var confirmed = "full"
        /// The outside edit, on the catalog.
        let edit: (inout JSONObject) -> Void
        /// What must be held back meanwhile.
        let held: (PrivacyRatchet.View) -> Bool
        /// Whether the card can be approved: a redacted item without a kind breaks the v0 rules, so its card waits
        /// for the person to give the kind back instead.
        var approvable = true
    }

    static func key(_ id: String) -> String { (try? Canonical.serialize(.string(id))) ?? id }

    static func item(_ id: String, in c: inout JSONObject, _ change: (inout JSONObject) -> Void) {
        c.set("open_items", .array((c["open_items"]?.arrayValue ?? []).map { it in
            guard it["id"] == .string(id), case .object(var o) = it else { return it }
            change(&o)
            return .object(o)
        }))
    }

    static let redacted = "estate-example-2026-009", plain = "estate-example-2026-007", titled = "estate-example-2026-012"

    let cases: [Case] = [
        Case(name: "disclosure raised", confirmed: "kind", edit: { c in
            var meta = c["meta"]?.objectValue ?? JSONObject()
            meta.set("disclosure", .str("full"))
            c.set("meta", .object(meta))
        }, held: { $0.disclosure == "kind" && $0.widenedTo == "full" }),
        Case(name: "redact cleared", edit: { item(redacted, in: &$0) { $0.remove("redact") } },
             held: { $0.redacted.contains(key(redacted)) && $0.lifted == [.str(redacted)] }),
        Case(name: "slice_title added to a redacted item", edit: { item(redacted, in: &$0) { $0.set("slice_title", .str("Invented subject")) } },
             held: { $0.titles[key(redacted)] == .str("[redacted]") }),
        Case(name: "slice_title added", edit: { item(plain, in: &$0) { $0.set("slice_title", .str("Invented subject")) } },
             held: { $0.titles[key(plain)] == .str("File the estate inventory with the notary") }),
        Case(name: "slice_title changed", edit: { item(titled, in: &$0) { $0.set("slice_title", .str("Invented subject")) } },
             held: { $0.titles[key(titled)] == .str("Maintenance invoices (house)") }),
        Case(name: "slice_title removed", edit: { item(titled, in: &$0) { $0.remove("slice_title") } },
             held: { $0.titles[key(titled)] == .str("Maintenance invoices (house)") }),
        Case(name: "tag added to a redacted item", edit: { item(redacted, in: &$0) { $0.set("tags", .array([.str("invented-subject")])) } },
             held: { $0.disclosure == "title" && $0.retagged.map(\.id) == [.str(redacted)] }),
        Case(name: "kind removed from a redacted item", edit: { item(redacted, in: &$0) { $0.remove("kind") } },
             held: { $0.unkinded == [.str(redacted)] && $0.kinds[key(redacted)] == .str("decision") }, approvable: false),
    ]

    @Test(arguments: 0..<8) func aLooseningMadeOutsideIsHeldUntilApproved(_ index: Int) throws {
        try #require(cases.count == 8)
        let c = cases[index]
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        store.testHookFullSync = { _ in 0 }
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        try store.apply([.init(op: "set_disclosure", args: JSONObject([(key: "disclosure", value: .string(c.confirmed))]), actor: user)], now: now)
        func catalog() throws -> JSONObject {
            try #require(try JSONParser.parse(try Data(contentsOf: folder.appendingPathComponent("catalog.json"))).value.objectValue)
        }
        #expect(try PrivacyRatchet.ensureCard(folder: folder, now: now) == nil, "\(c.name): a card before any edit")

        // The outside edit, recorded as one.
        var edited = try catalog()
        c.edit(&edited)
        try Data(JSONWriter.pretty(.object(edited)).utf8).write(to: folder.appendingPathComponent("catalog.json"))
        try store.settle(now: now)
        #expect(c.held(PrivacyRatchet.view(folder: folder, catalog: try catalog())), "\(c.name): not held back")
        let id = try #require(try PrivacyRatchet.ensureCard(folder: folder, now: now), "\(c.name): no privacy card")
        guard c.approvable else { return }

        // Approved, the found values stand and nothing is held.
        try store.approve(try ProposalStore.load(id, in: folder, expectedDigest: nil), now: now)
        let after = PrivacyRatchet.view(folder: folder, catalog: try catalog())
        #expect(!c.held(after), "\(c.name): still held after approval")
        #expect(after.retitled.isEmpty && after.lifted.isEmpty && after.retagged.isEmpty && after.widenedTo == nil, "\(c.name)")
        #expect(try PrivacyRatchet.ensureCard(folder: folder, now: now) == nil, "\(c.name): a card after approval")
    }
}
