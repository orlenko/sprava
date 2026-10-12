import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The model never sees the name of a binder at disclosure none, even when an outside edit raised it since: the
/// clerk knows it by an opaque label that code maps back. Invented data only.
@Suite(.serialized) struct CaptureFilingLabelTests {
    /// A typed note the way the app sends it: the event, then its notice.
    @discardableResult
    func note(_ s: PSetup, _ text: String, hint: String? = nil) throws -> String {
        let n = try s.producer.prepareNote(text, binderHint: hint, startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: n.id, digest: n.digest)
        try s.producer.publish(n)
        return n.id
    }

    @Test func aDisclosureNoneBinderGoesByALabel() async throws {
        let s = try pSetup()
        let secret = try namedBinder(s, name: "estate-secret", disclosure: "none")
        try FilingList(support: s.support).set(secret, .init(description: "Inventory and notary paperwork", filing: true))
        let filing = FilingList(support: s.support).binders(rows: [shelfRow(secret)], deviceID: s.commands.deviceID)
        let label = try #require(filing.first?.name)
        #expect(label.hasPrefix("binder-") && label != "estate-secret")
        try note(s, "File the estate inventory with the notary")
        _ = s.inbox.sweep(binders: [shelfRow(secret)], commands: s.commands, now: pNow)
        let work = try #require(s.inbox.nextForClerk())
        let model = BugModel([.obj([("items", .array([item("File the estate inventory", "File the inventory", "file")]))])])
        model.binder = label
        let interp = await Clerk(model: model).read(work.event, filing: filing, hint: nil, now: pNow)
        #expect(!model.seen.contains { $0.contains("estate-secret") })
        let out = s.inbox.commitClerk(work, interp, filing: filing, rows: [shelfRow(secret)], commands: s.commands, seconds: 1, now: pNow)
        #expect(out.filed == 1)
        #expect(ProposalStore.list(in: secret).contains { $0.0.state == "proposed" })
        // Without the filing list, the real name never resolves to it.
        #expect(FilingList(support: s.support).binders(rows: [shelfRow(secret)], deviceID: s.commands.deviceID).allSatisfy { $0.name != "estate-secret" })
    }

    @Test func aDisclosureRaisedOutsideNeverNamesTheBinderToTheClerk() throws {
        let s = try pSetup()
        let folder = try namedBinder(s, name: "estate-secret", disclosure: "none")
        try FilingList(support: s.support).set(folder, .init(description: "Inventory and notary paperwork", filing: true))
        let label = try #require(FilingList(support: s.support).binders(rows: [shelfRow(folder)], deviceID: "dev").first?.name)
        #expect(label.hasPrefix("binder-"))

        // Raised to full outside Sprava, no privacy card approved.
        let url = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(Data(contentsOf: url)).value.objectValue)
        var meta = try #require(catalog["meta"]?.objectValue)
        meta.set("disclosure", .str("full"))
        catalog.set("meta", .object(meta))
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
        #expect(PrivacyRatchet.disclosure(shelfRow(folder)) == "none")

        #expect(FilingList(support: s.support).binders(rows: [shelfRow(folder)], deviceID: "dev").map(\.name) == [label])
        #expect(try FilingList(support: s.support).name(of: shelfRow(folder)) == label)
        // A note naming it is not filed into it either.
        try note(s, "File the estate inventory with the notary", hint: "estate-secret")
        _ = s.inbox.sweep(binders: [shelfRow(folder)], commands: s.commands, now: pNow)
        #expect(!ProposalStore.list(in: folder).contains { $0.0.state == "proposed" })
        #expect(s.inbox.unfiled().count == 1)
    }
}
