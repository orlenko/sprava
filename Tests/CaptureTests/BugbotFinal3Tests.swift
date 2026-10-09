import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Darwin
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from Codex Bugbot's third pass over the final capture layer (PR #13). Invented data only.
@Suite(.serialized) struct BugbotFinal3Tests {
    let adapter = "11111111-2222-4333-8444-5555555555fe"

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return s
    }

    @discardableResult
    func sweep(_ s: PSetup) -> CaptureInbox.SweepResult { s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }

    func handToAnotherMac(_ folder: URL) throws {
        try Data(#"{"device": "another-invented-mac"}"#.utf8).write(to: folder.appendingPathComponent(".sprava/owner.json"))
    }

    // MARK: - MUST-FIX

    @Test func theCodeBuiltCardIsNotWithdrawnFromABinderAnotherMacOwnsNow() async throws {
        let s = try setup()
        let (event, digest) = try s.producer.writeNote("Call the invented notary about the deed", binderHint: "estate-example",
                                                       startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: event["id"]!.stringValue!, digest: digest)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: Date())
        let tier0 = try #require(pOpen(s).first)
        let work = try #require(s.inbox.nextForClerk())
        let interp = await Clerk(model: RecordingModel([.obj([("items", .array([
            item("Call the invented notary about the deed", "Call the invented notary"),
        ]))])])).read(work.event, filing: [bFiling(s)], hint: work.hint, now: pNow)
        // Between the reading and its commit, the binder is handed to another Mac.
        try handToAnotherMac(s.folder)
        let before = ProposalStore.list(in: s.folder).count
        let outcome = s.inbox.commitClerk(work, interp, filing: [bFiling(s)], rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        #expect(!outcome.replaced)
        #expect(ProposalStore.list(in: s.folder).count == before, "nothing is written into it")
        #expect(pOpen(s).map(\.id) == [tier0.id], "its code-built card is left as it is")
    }

    @Test func everyBinderWriteIsRefusedOnceTheBinderIsNotThisMacsToWrite() throws {
        let s = try setup()
        let card = Proposal.make(title: "An invented card", actor: JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t"))]),
                                 ops: [], provenance: JSONObject(), now: pNow)
        try BinderWrite.save(card, in: s.folder, deviceID: s.commands.deviceID)
        // Another Mac's binder: no save, no rejection, no rewrite.
        try handToAnotherMac(s.folder)
        #expect(throws: BinderWrite.NotWritable.self) { try BinderWrite.save(card, in: s.folder, deviceID: s.commands.deviceID) }
        #expect(throws: BinderWrite.NotWritable.self) { try BinderWrite.reject(card, in: s.folder, reason: "x", deviceID: s.commands.deviceID, now: pNow) }
        #expect(throws: BinderWrite.NotWritable.self) {
            try BinderWrite.rewriteTrusted(card.id, in: s.folder, commands: s.commands) { $0 }
        }
        #expect(ProposalStore.list(in: s.folder).first { $0.0.id == card.id }?.0.state == "proposed")
        // A binder whose writes are blocked (its catalog cannot be read) is refused the same way.
        let t = try setup()
        try Data("{ not json".utf8).write(to: t.folder.appendingPathComponent("catalog.json"))
        #expect(throws: BinderWrite.NotWritable.self) { try BinderWrite.save(card, in: t.folder, deviceID: t.commands.deviceID) }
    }

    @Test func aKeyFileInIntakeIsNeverReadToFingerprintIt() throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        try t.write(s, "credentials.json", #"{"password": "INVENTED-SECRET-7731"}"#)
        let key = s.folder.appendingPathComponent("intake/credentials.json")
        _ = s.watcher.scan(binders: t.rows(s), commands: s.commands, now: t.now)
        // Unreadable to this user: hashing it would fail, so a digest proves it was never opened.
        chmod(key.path, 0o000)
        defer { chmod(key.path, 0o600) }
        let prepared = s.watcher.prepare(binders: t.rows(s), deviceID: "dev", reader: .inProcess)
        #expect(prepared.digests[key.path]?.hasPrefix("unread:") == true)
        #expect(IntakeWatcher.digest(of: key)?.hasPrefix("unread:") == true)
    }

    // MARK: - Issues fixed here

    func check(_ s: PSetup, _ change: (inout JSONObject) -> Void) throws -> CaptureEvent.Check {
        let folder = s.producer.root.appendingPathComponent(adapter)
        let id = try pEvent(s, device: adapter, app: "adapter", ref: UUID().uuidString, revision: "1", text: "Invented note") { change(&$0) }
        return CaptureEvent.check(folder.appendingPathComponent("\(id).json"), deviceFolder: folder).0
    }

    @Test func everyMediaEntryIsValidated() throws {
        let s = try setup()
        let sha = JSONValue.string(String(repeating: "a", count: 64))
        let bad: [[(String, JSONValue)]] = [
            [("sha256", sha), ("of", .str("00000000-0000-4000-8000-000000000001"))],                          // no kind
            [("kind", .str("audio")), ("of", .str("00000000-0000-4000-8000-000000000001"))],                   // no sha256
            [("kind", .str("audio")), ("sha256", .str("not-hex")), ("of", .str("00000000-0000-4000-8000-000000000001"))],
            [("kind", .str("audio")), ("sha256", sha), ("of", .str("not an id"))],
            [("kind", .str("audio")), ("sha256", sha), ("of", .str("00000000-0000-4000-8000-000000000001")), ("path", .str("x.m4a")), ("bytes", .int(1))],
        ]
        for entry in bad {
            #expect(try check(s) { $0.set("media", .array([.obj(entry)])) } == .quarantined("media entry is not a copied file or a reuse"))
        }
        #expect(try check(s) { $0.set("media", .array([.obj([("kind", .str("audio")), ("sha256", sha),
                                                             ("of", .str("00000000-0000-4000-8000-000000000001"))])])) } == .complete(.capture))
    }

    @Test func aMissingOrMistypedFormatVersionIsQuarantinedNotDeferred() throws {
        let s = try setup()
        #expect(try check(s) { $0.remove("format_version") } == .quarantined("format_version is not text"))
        #expect(try check(s) { $0.set("format_version", .int(0)) } == .quarantined("format_version is not text"))
        #expect(try check(s) { $0.set("format_version", .str("1")) } == .deferred)
    }

    @Test func aCaptureRootThatCannotBeListedIsReported() throws {
        let s = try setup()
        chmod(s.producer.root.path, 0o300)
        defer { chmod(s.producer.root.path, 0o700) }
        #expect(sweep(s).rootUnlisted)
    }

    @Test func aCorrectionsCardCountsForTheOneMinuteMeasure() throws {
        let s = try setup()
        let id = try pEvent(s, device: adapter, app: "adapter", ref: "L1", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        try s.inbox.file(try #require(s.inbox.unfiled().first { $0.raw["provenance"]?["events"] == .array([.string(id)]) }).id,
                         into: s.folder, commands: s.commands)
        _ = try TekaStore(folder: s.folder).approve(try #require(pOpen(s).first), now: pNow)
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "L1", revision: "rev2", text: "Call the invented roofer Monday")
        let result = sweep(s)
        #expect(result.filed == 1 && result.latencies.count == 1)
    }
}
