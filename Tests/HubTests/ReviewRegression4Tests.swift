import BinderFormat
import BinderStore
import CryptoKit
import Darwin
import Foundation
@testable import Hub
import SpravaKit
import SpravaTestSupport
import Testing

/// Regression tests for the final Bugbot review of the hub layer. Each test names the finding it pins. Every value
/// is invented.
@Suite(.serialized) struct ReviewRegression4Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    let user = JSONObject([(key: "kind", value: .str("user"))])

    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-hub4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func item(_ id: String, extra: String = "") -> String {
        #"{"id":"\#(id)","title":"Invented task","status":"open","priority":"normal","due":"2026-11-01"\#(extra)}"#
    }

    func cat(_ f: URL) throws -> JSONObject {
        try JSONParser.parse(try Data(contentsOf: f.appendingPathComponent("catalog.json"))).value.objectValue!
    }

    func write(_ c: JSONObject, _ f: URL) throws {
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: f.appendingPathComponent("catalog.json"))
    }

    /// An adopted binder `tax` with the given items and log, and a spool with an inbox and an outbox; published once
    /// unless `publish` is false.
    func adoptedTax(_ root: URL, items: [String]? = nil, log: String = "[]", publish: Bool = true) throws -> (URL, URL) {
        let f = root.appendingPathComponent("tax", isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let open = (items ?? [item("a-1"), item("a-2")]).joined(separator: ",")
        let text = #"{"meta":{"schema_version":2,"name":"tax"},"documents":[],"open_items":[\#(open)],"processing_log":\#(log)}"#
        try Data(text.utf8).write(to: f.appendingPathComponent("catalog.json"))
        try TekaStore(folder: f).adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let s = root.appendingPathComponent("spool")
        for sub in ["inbox", "outbox"] {
            try FileManager.default.createDirectory(at: s.appendingPathComponent(sub), withIntermediateDirectories: true)
            chmod(s.appendingPathComponent(sub).path, 0o700)
        }
        chmod(s.path, 0o700)
        if publish {
            guard case .published = try HubLane.publish(f, root: s, now: now) else { throw TekaStore.Refused(reason: "first publish failed") }
        }
        return (f, s)
    }

    func sliceURL(_ s: URL, _ name: String = "tax") -> URL { s.appendingPathComponent("inbox/\(name).agenda.json") }

    func outbox(_ s: URL) -> URL { s.appendingPathComponent("outbox/tax.intake.json") }

    func openIDs(_ f: URL) throws -> [JSONValue] { try cat(f)["open_items"]?.arrayValue?.compactMap { $0["id"] } ?? [] }

    func editOutside(_ f: URL, _ id: String, _ change: (inout JSONObject) -> Void) throws {
        var c = try cat(f)
        c.set("open_items", .array((c["open_items"]?.arrayValue ?? []).map { v in
            guard var o = v.objectValue, o["id"] == .string(id) else { return v }
            change(&o)
            return .object(o)
        }))
        try write(c, f)
    }

    func narrowOutside(_ f: URL, to level: String) throws {
        var c = try cat(f)
        var meta = c["meta"]?.objectValue ?? JSONObject()
        meta.set("disclosure", .string(level))
        c.set("meta", .object(meta))
        try write(c, f)
    }

    func editCursors(_ f: URL, _ change: (inout JSONObject) -> Void) throws {
        let url = f.appendingPathComponent(".sprava/cursors.json")
        var c = try JSONParser.parse(try Data(contentsOf: url)).value.objectValue!
        change(&c)
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: url)
    }

    // Negative cursor offsets: a planted `lastLogCount` or `opCount` below zero is refused as damaged cursors,
    // never sliced with, which would stop the runtime.
    @Test func negativeCursorOffsetsAreRefused() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        func number(_ text: String) throws -> JSONValue { try JSONParser.parse(Data(text.utf8)).value }
        for field in ["lastLogCount", "opCount"] {
            let (negative, zero) = (try number("-1"), try number("0"))
            try editCursors(f) { $0.set(field, negative) }
            #expect(throws: TekaStore.Refused.self) { try HubLane.readCursors(f) }
            #expect(throws: TekaStore.Refused.self) { try HubLane.publish(f, root: s, now: now, force: true) }
            try editCursors(f) { $0.set(field, zero) }
        }
    }

    // Special cursor files: a FIFO at `.sprava/cursors.json` or `.sprava/slice-key` is refused at once instead of
    // stalling the drain on a read that waits for a writer.
    @Test func aFIFOInSpravaIsRefusedWithoutWaiting() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        try Data(#"{"completions":[{"id":"tax-a-1","action":"done"}]}"#.utf8).write(to: outbox(s))
        for name in ["cursors.json", "slice-key"] {
            let url = f.appendingPathComponent(".sprava/\(name)")
            let saved = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            #expect(mkfifo(url.path, 0o600) == 0)
            #expect(throws: TekaStore.Refused.self) { try HubLane.drain(f, root: s, now: now) }
            try FileManager.default.removeItem(at: url)
            try saved.write(to: url)
        }
        #expect(try openIDs(f).count == 2)
    }

    // Unsafe outbox JSON: a duplicate `completions` member is never read one way and rewritten another; the drain
    // fails and leaves the file byte for byte.
    @Test func anOutboxWithUnsafeJSONIsLeftAsItIs() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let body = Data(#"{"completions":[{"id":"tax-a-1","action":"done"}],"completions":[{"id":"tax-a-2","action":"done"}]}"#.utf8)
        try body.write(to: outbox(s))
        #expect(throws: TekaStore.Refused.self) { try HubLane.drain(f, root: s, now: now) }
        #expect(try openIDs(f).count == 2)
        #expect(try Data(contentsOf: outbox(s)) == body)
        #expect(throws: TekaStore.Refused.self) { try HubLane.acknowledge(file: outbox(s), applied: [("tax-a-1", nil)]) }
        #expect(try Data(contentsOf: outbox(s)) == body)
    }

    // Non-object completions: each one is counted as skipped, so a drain of nothing but malformed entries is not a
    // silent no-op.
    @Test func nonObjectCompletionsCountAsSkipped() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        try Data(#"{"completions":[7,"tax-a-1",["tax-a-2"]]}"#.utf8).write(to: outbox(s))
        let result = try HubLane.drain(f, root: s, now: now)
        #expect(result.skipped == 3 && result.applied == 0)
        #expect(FileManager.default.fileExists(atPath: outbox(s).path))
    }

    // Legacy closed ids: a log entry with an `id` closes that item whatever its action, and a `closed-duplicate`
    // closes its `item`; a hub completion for either is acknowledged, not left in the outbox forever.
    @Test func completionsForLegacyClosuresAreAcknowledged() throws {
        let root = try scratch()
        let log = #"[{"id":"a-8","action":"completed","date":"2026-01-02"},"#
            + #"{"item":"a-9","action":"closed-duplicate","at":"2026-02-03T10:00:00Z","op_id":"invented-op"}]"#
        let (f, s) = try adoptedTax(root, log: log)
        try Data(#"{"completions":[{"id":"tax-a-8","action":"done"},{"id":"a-9","action":"dropped"}]}"#.utf8).write(to: outbox(s))
        let result = try HubLane.drain(f, root: s, now: now)
        #expect(result.acknowledged == 2 && result.skipped == 0 && result.applied == 0)
        #expect(!FileManager.default.fileExists(atPath: outbox(s).path))
        #expect(try openIDs(f).count == 2)
    }

    // Recurring items: a `dropped` completion ends the series; a `done` still waits for the person.
    @Test func aDroppedCompletionEndsARecurringSeries() throws {
        let root = try scratch()
        let recurring = item("a-3", extra: #","recurrence":{"freq":"monthly","day":1}"#)
        let (f, s) = try adoptedTax(root, items: [item("a-1"), recurring])
        try Data(#"{"completions":[{"id":"tax-a-3","action":"done"}]}"#.utf8).write(to: outbox(s))
        let held = try HubLane.drain(f, root: s, now: now)
        #expect(held.waitingForYou == 1 && held.applied == 0)
        try Data(#"{"completions":[{"id":"tax-a-3","action":"dropped","at":"2026-10-07T09:00:00Z"}]}"#.utf8).write(to: outbox(s))
        let dropped = try HubLane.drain(f, root: s, now: now)
        #expect(dropped.applied == 1 && dropped.waitingForYou == 0)
        #expect(try openIDs(f) == [.str("a-1")])
        #expect(!FileManager.default.fileExists(atPath: outbox(s).path))
    }

    // The spool root: a drain refuses a root that others may write, or a root that is a link, as a publish does.
    @Test func aDrainRefusesAnUnsafeSpoolRoot() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        try Data(#"{"completions":[{"id":"tax-a-1","action":"done"}]}"#.utf8).write(to: outbox(s))
        chmod(s.path, 0o777)
        #expect(throws: TekaStore.Refused.self) { try HubLane.drain(f, root: s, now: now) }
        chmod(s.path, 0o700)
        let link = root.appendingPathComponent("spool-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: s)
        #expect(throws: TekaStore.Refused.self) { try HubLane.drain(f, root: link, now: now) }
        #expect(try openIDs(f).count == 2)
    }

    // An outbox folder that cannot be looked at is a failure the breaker sees, not a quiet no-op.
    @Test func anUnreadableOutboxFolderFailsTheDrain() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        chmod(s.path, 0o600)
        defer { chmod(s.path, 0o700) }
        #expect(throws: TekaStore.Refused.self) { try HubLane.drain(f, root: s, now: now) }
    }

    // An adopted binder whose catalog is invalid JSON fails the drain while a completion waits; a spool without a
    // completion for it stays quiet.
    @Test func anInvalidCatalogFailsTheDrain() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        try Data("{ invalid".utf8).write(to: f.appendingPathComponent("catalog.json"))
        #expect(try HubLane.drain(f, root: s, now: now) == HubLane.DrainResult())
        try Data(#"{"completions":[{"id":"tax-a-1","action":"done"}]}"#.utf8).write(to: outbox(s))
        #expect(throws: TekaStore.Refused.self) { try HubLane.drain(f, root: s, now: now) }
        #expect(FileManager.default.fileExists(atPath: outbox(s).path))
    }

    // Active chapters: a bare empty string is no chapter, and a list keeps only nonempty strings.
    @Test func activeChaptersKeepOnlyNonemptyStrings() throws {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        func chapters(_ meta: String) throws -> JSONValue {
            let c = try JSONParser.parse(Data(#"{"meta":{"schema_version":2,"name":"tax",\#(meta)},"open_items":[]}"#.utf8)).value.objectValue!
            return try HubLane.project(catalog: c, folderName: "tax", closedOnce: [], key: key, now: now).slice
        }
        let bare = try chapters(#""active_chapters":"""#)
        #expect(bare["active_chapters"] == .array([]) && bare["active_chapter"] == .null)
        let mixed = try chapters(#""active_chapters":["",3,{"x":1},"invented-chapter"]"#)
        #expect(mixed["active_chapters"] == .array([.str("invented-chapter")]))
        #expect(mixed["active_chapter"] == .str("invented-chapter"))
    }

    // Overwrite detection: another program rewriting the same items under a new `generated` stamp is noticed.
    @Test func aRewriteWithTheSameItemsIsNoticed() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        #expect(try HubLane.publish(f, root: s, now: now) == .unchanged)
        var shown = try JSONParser.parse(try Data(contentsOf: sliceURL(s))).value.objectValue!
        shown.set("generated", .str("2026-10-07T07:00:00Z"))
        try Data(JSONWriter.pretty(.object(shown)).utf8).write(to: sliceURL(s))
        #expect(try HubLane.publish(f, root: s, now: now) == .published(items: 2, overwrittenByOther: true))
        #expect(try HubLane.publish(f, root: s, now: now) == .unchanged)
    }

    // Former names: after the former name's `until` date another binder may hold it, so the first publish after the
    // rename removes the slice there only when it is still the one Sprava wrote.
    @Test func anExpiredFormerNamesSliceIsLeftToItsNewOwner() throws {
        let root = try scratch()
        let (old, s) = try adoptedTax(root)
        let f = old.deletingLastPathComponent().appendingPathComponent("tax-new", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: f)
        let args = JSONObject([(key: "name", value: .str("tax-new")), (key: "former", value: .str("tax")),
                               (key: "until", value: .str("2026-10-01"))])
        try TekaStore(folder: f).apply([.init(op: "rename_teka", args: args, actor: user)], now: now)
        let other = Data(#"{"teka":"tax","items":[{"id":"tax-b-1","title":"Invented other task"}]}"#.utf8)
        try other.write(to: sliceURL(s))
        #expect(try HubLane.publish(f, root: s, now: now) == .published(items: 2, overwrittenByOther: false))
        #expect(try Data(contentsOf: sliceURL(s)) == other)
    }

    // A colliding name: narrowing withdraws by the recorded name only while the file there is still Sprava's; a
    // slice another program wrote under the shared name since stays.
    @Test func aCollidingWithdrawalLeavesAnotherProgramsSlice() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let other = Data(#"{"teka":"tax","items":[{"id":"tax-b-1","title":"Invented other task"}]}"#.utf8)
        try other.write(to: sliceURL(s))
        try narrowOutside(f, to: "none")
        #expect(try HubLane.publish(f, root: s, now: now, nameCollides: true) == .removed)
        #expect(try Data(contentsOf: sliceURL(s)) == other)
        #expect(HubLane.loadCursors(f).sliceHash == nil)

        let (g, t) = try adoptedTax(try scratch())
        try narrowOutside(g, to: "none")
        #expect(try HubLane.publish(g, root: t, now: now, nameCollides: true) == .removed)
        #expect(!FileManager.default.fileExists(atPath: sliceURL(t).path))
    }

    // A binder that no longer reads as adopted (its op log gone) withdraws the slice its cursors recorded, while it
    // is still the one Sprava wrote.
    @Test func aBinderNoLongerAdoptedWithdrawsItsSlice() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        try FileManager.default.removeItem(at: f.appendingPathComponent(".sprava/ops.ndjson"))
        #expect(!Teka.read(f).isAdopted)
        guard case .notPublished = try HubLane.publish(f, root: s, now: now) else { Issue.record("expected no publish"); return }
        #expect(!FileManager.default.fileExists(atPath: sliceURL(s).path))
        #expect(HubLane.loadCursors(f).sliceHash == nil)
    }

    // An interrupted publish: the slice it wrote before its cursors were saved is still known as Sprava's, so the
    // next publish settles it instead of reporting it as another program's, and a narrowing withdraws it even under
    // a name collision.
    @Test func aSliceFromAnInterruptedPublishIsStillWithdrawn() throws {
        struct CutOff: Error {}
        let inbox = { (s: URL) in s.appendingPathComponent("inbox") }
        let (f, s) = try adoptedTax(try scratch())
        try editOutside(f, "a-1") { $0.set("title", .str("Invented changed task")) }
        #expect(throws: CutOff.self) {
            try HubLane.publishChecked(Teka.read(f), inbox: inbox(s), now: now, force: false, nameCollides: false,
                                       afterSliceWrite: { throw CutOff() })
        }
        // The slice the cut-off publish wrote is the one this publish would write: it is settled as Sprava's own.
        #expect(try HubLane.publish(f, root: s, now: now) == .unchanged)
        #expect(HubLane.loadCursors(f).pending == nil)

        let (g, t) = try adoptedTax(try scratch())
        try editOutside(g, "a-1") { $0.set("title", .str("Invented changed task")) }
        #expect(throws: CutOff.self) {
            try HubLane.publishChecked(Teka.read(g), inbox: inbox(t), now: now, force: false, nameCollides: false,
                                       afterSliceWrite: { throw CutOff() })
        }
        try narrowOutside(g, to: "none")
        #expect(try HubLane.publish(g, root: t, now: now, nameCollides: true) == .removed)
        #expect(!FileManager.default.fileExists(atPath: sliceURL(t).path))
        #expect(HubLane.loadCursors(g).pending == nil && HubLane.loadCursors(g).sliceHash == nil)
    }

    // A pending slice is settled before a rename's publish replaces its record: the slice a cut-off publish wrote
    // under the former name goes, even after that name expired, and a later narrowing leaves nothing on the hub.
    @Test func aPendingSliceSurvivesARenameUntilItIsRetired() throws {
        struct CutOff: Error {}
        let (old, s) = try adoptedTax(try scratch())
        try editOutside(old, "a-1") { $0.set("title", .str("Invented changed task")) }
        #expect(throws: CutOff.self) {
            try HubLane.publishChecked(Teka.read(old), inbox: s.appendingPathComponent("inbox"), now: now, force: false,
                                       nameCollides: false, afterSliceWrite: { throw CutOff() })
        }
        let f = old.deletingLastPathComponent().appendingPathComponent("tax-new", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: f)
        let args = JSONObject([(key: "name", value: .str("tax-new")), (key: "former", value: .str("tax")),
                               (key: "until", value: .str("2026-10-01"))])
        try TekaStore(folder: f).apply([.init(op: "rename_teka", args: args, actor: user)], now: now)
        #expect(try HubLane.publish(f, root: s, now: now) == .published(items: 2, overwrittenByOther: false))
        #expect(!FileManager.default.fileExists(atPath: sliceURL(s).path))
        try narrowOutside(f, to: "none")
        #expect(try HubLane.publish(f, root: s, now: now) == .removed)
        let left = try FileManager.default.contentsOfDirectory(atPath: s.appendingPathComponent("inbox").path)
        #expect(left.filter { $0.hasSuffix(".agenda.json") }.isEmpty)
    }

    // A first publish cut off after its write is settled with the log position it was built from, so the closures
    // already in the log when it ran are not sent to the hub as new ones.
    @Test func aSettledFirstPublishSendsNoOldClosures() throws {
        struct CutOff: Error {}
        let log = #"[{"id":"a-8","action":"done","date":"2026-01-02"},{"id":"a-9","action":"dropped","date":"2026-02-03"}]"#
        let (f, s) = try adoptedTax(try scratch(), log: log, publish: false)
        #expect(throws: CutOff.self) {
            try HubLane.publishChecked(Teka.read(f), inbox: s.appendingPathComponent("inbox"), now: now, force: false,
                                       nameCollides: false, afterSliceWrite: { throw CutOff() })
        }
        #expect(try HubLane.publish(f, root: s, now: now) == .unchanged)
        let items = try JSONParser.parse(try Data(contentsOf: sliceURL(s))).value["items"]?.arrayValue ?? []
        #expect(items.count == 2 && !items.contains { $0["title"] == .str("[closed]") })
        #expect(HubLane.loadCursors(f).lastLogCount == 2)
    }

    // A forced refresh cut off before it replaced the slice is not settled by its new stamp: the slice on the spool
    // is still the earlier one, Sprava's own, and the next publish raises no overwrite alarm.
    @Test func aRefreshCutOffBeforeItsWriteRaisesNoAlarm() throws {
        struct CutOff: Error {}
        let (f, s) = try adoptedTax(try scratch())
        #expect(throws: CutOff.self) {
            try HubLane.publishChecked(Teka.read(f), inbox: s.appendingPathComponent("inbox"), now: now.addingTimeInterval(3600),
                                       force: true, nameCollides: false, beforeSliceWrite: { throw CutOff() })
        }
        #expect(try HubLane.publish(f, root: s, now: now) == .unchanged)
        #expect(HubLane.loadCursors(f).pending == nil)
    }

    // Cursors written before the stamp was recorded take it from the slice they match, so a later rewrite that
    // changes only the stamp is noticed.
    @Test func cursorsWithoutAStampGainOneFromTheirSlice() throws {
        let (f, s) = try adoptedTax(try scratch())
        try editCursors(f) { $0.remove("generated") }
        #expect(try HubLane.publish(f, root: s, now: now) == .unchanged)
        #expect(HubLane.loadCursors(f).generated != nil)
        var shown = try JSONParser.parse(try Data(contentsOf: sliceURL(s))).value.objectValue!
        shown.set("generated", .str("2026-10-07T07:00:00Z"))
        try Data(JSONWriter.pretty(.object(shown)).utf8).write(to: sliceURL(s))
        #expect(try HubLane.publish(f, root: s, now: now) == .published(items: 2, overwrittenByOther: true))
    }

    // Redaction cursors: a publish cut off right after its slice write has already recorded what that slice hid, so
    // an outside edit that then removes the redaction does not expose the title on the next publish.
    @Test func aPublishCutOffAfterItsWriteKeepsTheRedaction() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        try editOutside(f, "a-1") { $0.set("redact", .bool(true)) }
        struct CutOff: Error {}
        let inbox = s.appendingPathComponent("inbox")
        #expect(throws: CutOff.self) {
            try HubLane.publishChecked(Teka.read(f), inbox: inbox, now: now, force: false, nameCollides: false,
                                       afterSliceWrite: { throw CutOff() })
        }
        let hidden = try JSONParser.parse(try Data(contentsOf: sliceURL(s))).value["items"]?.arrayValue?.first
        #expect(hidden?["title"] == .str("[redacted]"))
        try editOutside(f, "a-1") { $0.remove("redact") }
        _ = try HubLane.publish(f, root: s, now: now)
        let first = try JSONParser.parse(try Data(contentsOf: sliceURL(s))).value["items"]?.arrayValue?.first
        #expect(first?["title"] == .str("[redacted]"))
        #expect(first?["id"] != .str("tax-a-1"))
    }
}
