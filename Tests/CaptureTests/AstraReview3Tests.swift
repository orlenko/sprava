import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the third adversarial review of increment 1 (closed items under the title ratchet, rewrites
/// of tampered cards, the clerk and the disclosure ratchet, readings that could not be written, waiting parties on
/// repair cards, failed state backups, and file names in the capture journal). Invented data only.
@Suite(.serialized) struct AstraReview3Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    /// Rewrites a stored card's file the way another program would, keeping it valid JSON.
    func tamper(_ id: String, in folder: URL, _ change: (inout JSONObject) -> Void) throws -> Data {
        let url = ProposalStore.dir(folder).appendingPathComponent("\(id).json")
        var raw = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
        change(&raw)
        let data = Data(JSONWriter.pretty(.object(raw)).utf8)
        try data.write(to: url)
        return data
    }

    /// A card's first add_item retitled, as a tampering program might.
    func retitleFirstItem(_ raw: inout JSONObject) {
        var ops = raw["ops"]?.arrayValue ?? []
        guard case .object(var op)? = ops.first, var args = op["args"]?.objectValue, var item = args["item"]?.objectValue else { return }
        item.set("title", .str("Invented tampered task"))
        args.set("item", .object(item))
        op.set("args", .object(args))
        ops[0] = .object(op)
        raw.set("ops", .array(ops))
    }

    /// A typed note the way the app sends it: the event, then its notice.
    func note(_ s: PSetup, _ text: String, hint: String? = nil) throws {
        let n = try s.producer.prepareNote(text, binderHint: hint, startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: n.id, digest: n.digest)
        try s.producer.publish(n)
    }

    func journal(_ s: PSetup) -> String { (try? String(contentsOf: s.inbox.journalURL, encoding: .utf8)) ?? "" }

    @Test func annotatingATamperedCodeBuiltCardLeavesItUnverified() async throws {
        let s = try pSetup()
        try note(s, "File the estate inventory with the notary", hint: "estate-example")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let work = try #require(s.inbox.nextForClerk())
        #expect(work.tier0Binder != nil)
        #expect(s.commands.isTrusted(work.tier0, in: s.folder))
        let changed = try tamper(work.tier0, in: s.folder, retitleFirstItem)

        let filing = [FilingBinder(name: "estate-example", description: "Estate: notary, inventory", folder: s.folder,
                                   words: FilingBinder.significantWords("estate inventory notary"),
                                   openItems: FilingBinder.candidates(catalog: Teka.read(s.folder).catalog))]
        let model = RecordingModel([.obj([("items", .array([item("File the estate inventory", "File the inventory", "file")]))])])
        model.dup = ("estate-example-2026-007", "same")
        let interp = await Clerk(model: model).read(work.event, filing: filing, hint: nil, now: pNow)
        let out = s.inbox.commitClerk(work, interp, filing: filing, rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        #expect(!out.replaced)
        // Not annotated, not trusted again: it can only be rejected.
        #expect(try Data(contentsOf: ProposalStore.dir(s.folder).appendingPathComponent("\(work.tier0).json")) == changed)
        #expect(!s.commands.isTrusted(work.tier0, in: s.folder))
        #expect(journal(s).contains("card_changed_outside"))
    }

    @Test func aPrivacyRaiseNeverTrustsATamperedCard() throws {
        let s = try pSetup()
        let adapter = "11111111-2222-4333-8444-5555555555c1"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        let first = try pEvent(s, device: adapter, app: "adapter", ref: "T1", revision: "rev1", text: "Meet the invented notary about the deed")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let unfiled = try #require(s.inbox.unfiled().first)
        try s.inbox.file(unfiled.id, into: s.folder, commands: s.commands)
        let changed = try tamper(unfiled.id, in: s.folder, retitleFirstItem)

        let raise = try pEvent(s, device: adapter, app: "adapter", ref: "T1", revision: "rev1", text: "Meet the invented notary about the deed") {
            $0.set("sensitivity", .str("private")); $0.set("supersedes", .string(first))
        }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(try Data(contentsOf: ProposalStore.dir(s.folder).appendingPathComponent("\(unfiled.id).json")) == changed)
        #expect(!s.commands.isTrusted(unfiled.id, in: s.folder))
        // Nothing to retry: the card can never be approved.
        #expect(try s.inbox.readState().raises?[raise] == nil)
        #expect(journal(s).contains("card_changed_outside"))
    }

    // MARK: - 7. A malformed capture file name never reaches the journal

    @Test func aMalformedCaptureFileNameIsNotJournaled() throws {
        let s = try pSetup()
        let device = s.producer.root.appendingPathComponent(pDevice)
        try AtomicFile.makePrivateFolder(device)
        try Data(#"{"format": "sprava-capture-event"}"#.utf8).write(to: device.appendingPathComponent("Confidential appointment.json"))
        let r = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(r.quarantined == 1)
        let text = journal(s)
        #expect(text.contains("quarantined") && text.contains("invalid-name"), "\(text)")
        #expect(!text.contains("Confidential"), "\(text)")
    }
}
