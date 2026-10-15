import BinderFormat
import BinderStore
import Capture
import Clerk
import ClerkTestSupport
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// A note typed on a binder's page names that binder, and stays there through the code-built card and the clerk,
/// on the filing list or not; and an adopted binder is on the filing list until the person takes it off.
/// Temporary folders and invented binders only.
@Suite(.serialized) struct BinderNoteFilingTests: BinderCommandFixture {
    func context(_ c: Commands, rows: [URL]) -> JobContext {
        JobContext(support: c.support, commands: c, rows: { Shelf.rows(registry: nil, picked: rows) }, commandQueue: nil, log: { _ in })
    }

    func settings(_ c: Commands, _ folder: URL, _ fields: [(String, JSONValue)] = []) throws -> JSONValue {
        try call(c, [("command", .str("binder_settings")), ("binder", .string(folder.path))] + fields)
    }

    /// Writes a note the way the binder page's note box does: this binder's name as its hint, then the notice.
    func noteTyped(in folder: URL, _ text: String, _ c: Commands) throws {
        let device = "00000000-0000-4000-8000-000000000001"
        try c.inbox.registerProducer(folder: device, app: "sprava")
        let producer = CaptureProducer(root: c.inbox.root, deviceID: device, support: c.support)
        let (event, digest) = try producer.writeNote(text, binderHint: Teka.read(folder).name, startedAt: now, savedAt: now, locale: "en-CA")
        try c.inbox.recordNotice(event: try #require(event["id"]?.stringValue), digest: digest, now: now)
    }

    func open(_ folder: URL) -> [Proposal] { ProposalStore.list(in: folder).map(\.0).filter { $0.state == "proposed" } }

    /// A lifeproj binder under its own name, adopted and approved to ready.
    func adopted(_ c: Commands, _ name: String) throws -> URL {
        let folder = try makeTeka(fixture: "lifeproj-v2-live", folderName: name) { folder in
            let url = folder.appendingPathComponent("catalog.json")
            var catalog = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
            var meta = catalog["meta"]?.objectValue ?? JSONObject()
            meta.set("name", .string(name))
            catalog.set("meta", .object(meta))
            try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
        }
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path)), ("in_registry", .bool(true))])
        for card in try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? [] {
            _ = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        }
        #expect(Teka.read(folder).name == name && Teka.read(folder).isAdopted)
        return folder
    }

    @Test func aNoteTypedInABinderOffTheFilingListIsFiledThereByTheClerk() throws {
        let c = commands()
        let folder = try adopted(c, "acme")
        let other = try adopted(c, "globex")
        try #require(c.inbox.root.standardizedFileURL.path == c.support.appendingPathComponent("Captures").standardizedFileURL.path)
        _ = try settings(c, folder, [("description", .str("Invented acme paperwork")), ("filing", .bool(false))])
        _ = try settings(c, other, [("description", .str("Invented other paperwork")), ("filing", .bool(true))])
        #expect(FilingList(support: c.support).binders(rows: Shelf.rows(registry: nil, picked: [folder, other]), deviceID: c.deviceID)
            .map(\.folder.standardizedFileURL.path) == [other.standardizedFileURL.path])
        try noteTyped(in: folder, "Renew the invented acme permit", c)
        _ = c.inbox.sweep(binders: Shelf.rows(registry: nil, picked: [folder, other]), commands: c, now: now)
        let tier0 = try #require(open(folder).first)

        // The clerk reads the note and keeps it in this binder, though the binder is off the list and another is on it.
        let answer = JSONValue.obj([("items", .array([.obj([
            ("quote", .str("Renew the invented acme permit")), ("title", .str("Renew the acme permit")), ("action", .str("other"))])]))])
        let model = ScriptedModel(extractions: [answer], binders: ["acme": Teka.read(other).name], contextSize: 8192)
        let result = ClerkJob.run(context(c, rows: [folder, other]), model: .success(model))
        #expect(result.outcome == .ok && result.read == 1)
        let cards = open(folder)
        #expect(cards.count == 1)
        #expect(cards.first?.id != tier0.id)
        #expect(cards.first?.ops.first?["args"]?["item"]?["title"] == .str("Renew the acme permit"))
        #expect(open(other).isEmpty)
        #expect(c.inbox.unfiled().isEmpty)
        // The person named the binder, so no binder call was made.
        #expect(!model.prompts.contains { $0.contains("Binders:") })
    }

    @Test func anAdoptedBinderIsOnTheFilingListUntilThePersonTakesItOff() throws {
        let c = commands()
        let folder = try adopted(c, "acme")
        let rows = { Shelf.rows(registry: nil, picked: [folder]) }
        #expect(try settings(c, folder)["filing"] == .bool(true))
        #expect(FilingList(support: c.support).binders(rows: rows(), deviceID: c.deviceID).map(\.name) == [Teka.read(folder).name])

        // With no line about it, the binder is still offered by its name.
        #expect(try settings(c, folder, [("description", .str("")), ("filing", .bool(true))])["filing"] == .bool(true))
        #expect(FilingList(support: c.support).binders(rows: rows(), deviceID: c.deviceID).count == 1)

        #expect(try settings(c, folder, [("filing", .bool(false))])["filing"] == .bool(false))
        #expect(try settings(c, folder)["filing"] == .bool(false))
        #expect(FilingList(support: c.support).binders(rows: rows(), deviceID: c.deviceID).isEmpty)
    }

    @Test func twoBindersOfOneNameAreOfferedForNeither() throws {
        let c = commands()
        let first = try adopted(c, "acme")
        let second = try adopted(c, "acme")
        let other = try adopted(c, "globex")
        let rows = Shelf.rows(registry: nil, picked: [first, second, other])
        let list = FilingList(support: c.support)
        #expect(list.binders(rows: rows, deviceID: c.deviceID).map(\.name) == ["globex"])
        // A note naming that name is not offered either: the name cannot tell the two apart.
        #expect(list.binders(rows: rows, deviceID: c.deviceID, hint: "acme").map(\.name) == ["globex"])
        // Once one is taken off the list, the other is the only one the name means there.
        _ = try settings(c, second, [("filing", .bool(false))])
        #expect(list.binders(rows: rows, deviceID: c.deviceID).map(\.folder.standardizedFileURL.path).sorted()
            == [first, other].map(\.standardizedFileURL.path).sorted())
    }

    @Test func aPrivateBinderStaysOffTheListUntilThePersonWritesItsLine() throws {
        let c = commands()
        let folder = try adopted(c, "acme")
        #expect(try apply(c, folder, "set_disclosure", .obj([("disclosure", .str("none"))]))["ok"] == .bool(true))
        let rows = Shelf.rows(registry: nil, picked: [folder])
        #expect(try settings(c, folder)["filing"] == .bool(false))
        #expect(FilingList(support: c.support).binders(rows: rows, deviceID: c.deviceID).isEmpty)
        // Its name is never offered, not even for a note that names it.
        #expect(FilingList(support: c.support).binders(rows: rows, deviceID: c.deviceID, hint: Teka.read(folder).name).isEmpty)
        let refused = try settings(c, folder, [("description", .str("")), ("filing", .bool(true))])
        #expect(refused["ok"] == .bool(false))
        #expect(try settings(c, folder, [("description", .str("Invented papers")), ("filing", .bool(true))])["filing"] == .bool(true))
        #expect(FilingList(support: c.support).binders(rows: rows, deviceID: c.deviceID).first?.name.hasPrefix("binder-") == true)
    }
}
