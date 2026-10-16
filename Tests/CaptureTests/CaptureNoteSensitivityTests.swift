import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import CryptoKit
import Foundation
import Hub
import SpravaKit
import SpravaTestSupport
import Testing

/// Source privacy survives note preparation, publication and explicit Inbox filing (capture-event-v0 §6.4, §8.1).
/// Temporary fixtures only; no live runtime, binder or credential access.
@Suite struct CaptureNoteSensitivityTests {
    @Test func preparedAndImmediateNotesCarryTheRequestedSensitivityInTheirBytes() throws {
        let s = try pSetup()
        for markedPrivate in [false, true] {
            let expected = JSONValue.str(markedPrivate ? "private" : "unmarked")
            let note = try s.producer.prepareNote("Call the invented roofer", isPrivate: markedPrivate,
                                                  startedAt: pNow, savedAt: pNow, locale: "en-CA")
            #expect(note.event["sensitivity"] == expected)
            #expect(try JSONParser.parse(note.bytes).value["sensitivity"] == expected)
            let digest = "sha256:" + SHA256.hash(data: note.bytes).map { String(format: "%02x", $0) }.joined()
            #expect(note.digest == digest)
            try s.producer.publish(note)
            let saved = try Data(contentsOf: s.producer.folder.appendingPathComponent(note.id + ".json"))
            #expect(saved == note.bytes)
            let immediate = try s.producer.writeNote("Keep the invented estimate", isPrivate: markedPrivate,
                                                     startedAt: pNow, savedAt: pNow, locale: "en-CA")
            #expect(immediate.event["sensitivity"] == expected)
            let bytes = try Data(contentsOf: s.producer.folder.appendingPathComponent(immediate.event["id"]!.stringValue! + ".json"))
            #expect(try JSONParser.parse(bytes).value["sensitivity"] == expected)
        }
    }

    @Test func anOrdinaryNoteStillDefaultsToUnmarked() throws {
        let s = try pSetup()
        let prepared = try s.producer.prepareNote("Call the invented roofer", startedAt: pNow, savedAt: pNow)
        let immediate = try s.producer.writeNote("Keep the invented estimate", startedAt: pNow, savedAt: pNow)
        #expect(prepared.event["sensitivity"] == .str("unmarked"))
        #expect(immediate.event["sensitivity"] == .str("unmarked"))
    }

    @Test func aPrivateNoteFiledFromTheInboxStaysRedactedAfterDisclosureWidens() throws {
        let s = try pSetup()
        let folder = try namedBinder(s, name: "private-example", disclosure: "none")
        let note = try s.producer.prepareNote("Call the invented roofer", isPrivate: true,
                                              startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: note.id, digest: note.digest)
        try s.producer.publish(note)
        _ = s.inbox.sweep(binders: [shelfRow(folder)], commands: s.commands, now: pNow)
        let waiting = try #require(s.inbox.unfiled().first)
        #expect(waiting.raw["provenance"]?["private"] == .bool(true))
        #expect(waiting.ops.allSatisfy { $0["args"]?["item"]?["redact"] == .bool(true) })
        try s.inbox.file(waiting.id, into: folder, commands: s.commands)
        let filed = try #require(ProposalStore.list(in: folder).map(\.0).first { $0.id == waiting.id })
        let store = TekaStore(folder: folder)
        _ = try store.approve(filed, now: pNow)
        let item = try #require(Teka.read(folder).items.first { $0.title == "Call the invented roofer" })
        #expect(item.raw["redact"] == .bool(true))
        let user = JSONObject([(key: "kind", value: .str("user"))])
        _ = try store.apply([.init(op: "set_disclosure", args: JSONObject([(key: "disclosure", value: .str("full"))]), actor: user)], now: pNow)
        let catalog = try #require(Teka.read(folder).catalog)
        let (slice, ids) = try HubLane.project(catalog: catalog, folderName: folder.lastPathComponent, closedOnce: [],
                                             key: SymmetricKey(size: .bits256), now: pNow)
        let itemID = try #require(item.raw["id"])
        let publicID = try #require(ids[try Canonical.serialize(itemID)])
        let projected = try #require(slice["items"]?.arrayValue?.first { $0["id"] == .string(publicID) })
        #expect(projected["title"] == .str("[redacted]"))
        #expect(!JSONWriter.compact(slice).contains("Call the invented roofer"))
        let kept = Teka.read(folder).items.first { $0.id == item.id }
        #expect(kept?.raw["redact"] == .bool(true))
    }
}
