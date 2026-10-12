import BinderStore
import Capture
import CaptureTestSupport
import Darwin
import Extract
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// Filing through the command table when a move was cut short or crashed, a privacy raise reaching every item a
/// card writes to, and an unreadable record of trusted cards left as it is. Invented data only.
@Suite(.serialized) struct FilingRecoveryTests {
    let clerk = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("none"))])

    let garbage = Data("{\"broken".utf8)

    func note(_ s: PSetup, _ text: String, hint: String? = nil) throws -> String {
        let n = try s.producer.prepareNote(text, binderHint: hint, startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: n.id, digest: n.digest)
        try s.producer.publish(n)
        return n.id
    }

    func call(_ s: PSetup, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj(fields)), now: pNow, today: today)).value
    }

    func listed(_ s: PSetup, _ id: String) throws -> JSONValue? {
        try call(s, [("command", .str("proposals")), ("binder", .string(s.folder.path))])["proposals"]?.arrayValue?.first { $0["id"] == .string(id) }
    }

    func op(_ name: String, _ args: [(String, JSONValue)]) -> JSONObject {
        JSONObject([(key: "op", value: .string(name)), (key: "args", value: .obj(args))])
    }

    // MARK: - 2. A raise to private redacts every item a waiting card writes to

    @Test func raisingToPrivateRedactsEveryItemACardWritesTo() throws {
        let s = try pSetup()
        try bAddItem(s, id: "estate-example-2026-030", title: "Ask about the invented deed")
        try bAddItem(s, id: "estate-example-2026-031", title: "Return the invented keys")
        try bAddItem(s, id: "estate-example-2026-032", title: "Sort the invented letters")
        let event = "01a10000-0000-7000-8000-0000000000b2"
        let ops = [
            op("set_status", [("id", .str("estate-example-2026-030")), ("status", .str("waiting")),
                              ("waiting_on", .str("Invented Notary Office")), ("follow_up_at", .str("2026-10-20"))]),
            op("update_item", [("id", .str("estate-example-2026-031")), ("set", .obj([("notes", .str("left with the invented neighbour"))]))]),
            op("complete", [("id", .str("estate-example-2026-032")), ("closed_at", .str("2026-10-06T13:00:00Z")), ("source", .str("capture"))]),
        ]
        let card = Proposal.make(title: "Three changes from a note", actor: clerk, ops: ops,
                                 provenance: JSONObject([(key: "events", value: .array([.string(event)]))]), now: pNow)
        try ProposalStore.save(card, in: s.folder)
        try s.commands.trustProposals([card.id], in: s.folder)

        #expect(s.inbox.raisePrivacy(chain: [event], binders: pRows(s), commands: s.commands, now: pNow))
        let rewritten = try #require(pOpen(s).first { $0.id == card.id })
        #expect(rewritten.raw["provenance"]?["private"] == .bool(true))
        for (n, name) in [(30, "set_status"), (31, "update_item"), (32, "complete")] {
            let id = JSONValue.string("estate-example-2026-0\(n)")
            let redacts = rewritten.ops.firstIndex { $0["op"] == .str("update_item") && $0["args"]?["id"] == id && $0["args"]?["set"]?["redact"] == .bool(true) }
            let writes = rewritten.ops.lastIndex { $0["op"] == .string(name) && $0["args"]?["id"] == id }
            #expect(redacts != nil && writes != nil && redacts! <= writes!, "item \(n)")
            #expect(redacts.map { rewritten.ops[$0]["args"]?["set"]?["kind"] } == .str("other"), "item \(n)")
        }
        // Approved as shown, the party it waits on never reaches the hub.
        let shown = try #require(try listed(s, card.id))
        #expect(shown["verified"] == .bool(true))
        let r = try call(s, [("command", .str("approve")), ("binder", .string(s.folder.path)), ("proposal", .string(card.id)), ("digest", shown["digest"]!)])
        #expect(r["ok"] == .bool(true), "\(r)")
        let slice = JSONWriter.compact(.array(try bSlice(s.folder)))
        #expect(!slice.contains("Invented Notary Office") && !slice.contains("invented deed") && !slice.contains("invented keys"))
    }


    // MARK: - 5. A digest record that cannot be read is never saved over

    @Test func anUnreadableDigestRecordIsLeftAsItIs() throws {
        let s = try pSetup()
        let first = Proposal.make(title: "Invented card", actor: clerk, ops: [], now: pNow)
        try ProposalStore.save(first, in: s.folder)
        try s.commands.trustProposals([first.id], in: s.folder)
        try garbage.write(to: s.commands.digestsURL)

        let second = Proposal.make(title: "Another invented card", actor: clerk, ops: [], now: pNow)
        try ProposalStore.save(second, in: s.folder)
        #expect(throws: (any Error).self) { try s.commands.trustProposals([second.id], in: s.folder) }
        #expect(try call(s, [("command", .str("proposals")), ("binder", .string(s.folder.path))])["ok"] == .bool(false))
        #expect(try Data(contentsOf: s.commands.digestsURL) == garbage)
        // Only a missing record is an empty one.
        try FileManager.default.removeItem(at: s.commands.digestsURL)
        #expect(try s.commands.loadDigests().isEmpty)
    }

    // MARK: - 8. Filing an Inbox card never loses it

    @Test func aFilingCutShortNeverLosesTheCard() throws {
        let s = try pSetup()
        _ = try note(s, "Send the invented form")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let card = try #require(s.inbox.unfiled().first)
        // A binder that cannot take the card: the Inbox keeps it.
        let proposals = try ProposalStore.checkedDir(s.folder, create: true)
        chmod(proposals.path, 0o500)
        #expect(throws: (any Error).self) { try s.inbox.file(card.id, into: s.folder, commands: s.commands) }
        chmod(proposals.path, 0o700)
        #expect(s.inbox.unfiled().map(\.id) == [card.id])

        // A crash after the binder's copy was saved and trusted, before the Inbox let go: both hold the card...
        var raw = card.raw
        raw.remove("binder")
        try ProposalStore.save(Proposal(raw: raw), in: s.folder)
        try s.commands.trustProposals([card.id], in: s.folder)
        #expect(s.inbox.unfiled().map(\.id) == [card.id])
        // ...until the next sweep, which drops the Inbox's copy; the binder's stays approvable.
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(s.inbox.unfiled().isEmpty)
        #expect(pOpen(s).map(\.id) == [card.id])
        #expect(try listed(s, card.id)?["verified"] == .bool(true))
    }

    @Test func filingAgainAfterACrashOnlyFinishesTheMove() throws {
        let s = try pSetup()
        _ = try note(s, "Send the invented form")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let card = try #require(s.inbox.unfiled().first)
        var raw = card.raw
        raw.remove("binder")
        try ProposalStore.save(Proposal(raw: raw), in: s.folder)
        try s.commands.trustProposals([card.id], in: s.folder)
        let digest = try #require(try listed(s, card.id)?["digest"])

        try s.inbox.file(card.id, into: s.folder, commands: s.commands)
        #expect(s.inbox.unfiled().isEmpty)
        #expect(pOpen(s).map(\.id) == [card.id])
        #expect(try listed(s, card.id)?["digest"] == digest)
    }
}
