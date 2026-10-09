import BinderFormat
import BinderStore
import Capture
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct MeasuresTests {
    @Test func theMinuteAndHandEditsAreCountedFromTheRecords() throws {
        let now = Date()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-measures-\(UUID().uuidString)")
        let support = base.appendingPathComponent("support")
        let root = CaptureInbox.defaultRoot(support: support)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = commands.handle(JSONWriter.compact(.obj([("command", .str("adopt")), ("binder", .string(folder.path))])), now: now)
        let inbox = CaptureInbox(root: root, support: support)
        let device = "0f0e0d0c-0b0a-4908-8706-050403020100"
        try inbox.registerProducer(folder: device, app: "sprava")
        let producer = CaptureProducer(root: root, deviceID: device, support: support)
        let note = try producer.prepareNote("Call the invented notary", startedAt: now, savedAt: now)
        try inbox.recordNotice(event: note.id, digest: note.digest)   // as the app does, before publishing
        try producer.publish(note)
        let rows = [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))]
        _ = inbox.sweep(binders: rows, commands: commands, now: now)
        // A hand edit of the catalog, absorbed on the next write.
        var catalog = try #require(Teka.read(folder).catalog)
        var meta = try #require(catalog["meta"]?.objectValue)
        meta.set("note", .str("edited by hand"))
        catalog.set("meta", .object(meta))
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: folder.appendingPathComponent("catalog.json"))
        try TekaStore(folder: folder).apply([.init(op: "update_item", args: JSONObject([(key: "id", value: .str("estate-example-2026-007")),
                                                                                        (key: "set", value: .obj([("priority", .str("low"))]))]),
                                                   actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        let today = CalendarDate.today(now: now)
        let r = Measures(support: support).compute(rows: rows, from: today.adding(days: -1), to: today, now: now)
        #expect(r.captures == 1 && r.withinMinute == 1)
        #expect(r.externalEdits.count == 1)
        #expect(r.shareHand == 1)
        let text = Measures.text(r)
        #expect(text.contains("hand edits of catalog.json: 1 (miss)"))
        #expect(!text.contains("notary"))   // counts only, never titles or text
    }
}
