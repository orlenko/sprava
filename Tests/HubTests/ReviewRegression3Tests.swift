import BinderFormat
import BinderStore
import Darwin
import Foundation
@testable import Hub
import SpravaKit
import SpravaTestSupport
import Testing

/// Regression tests for the second review of the hub layer. Each test names the finding it pins.
@Suite(.serialized) struct ReviewRegression3Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-hub3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func item(_ id: String) -> String {
        #"{"id":"\#(id)","title":"Invented task","status":"open","priority":"normal","due":"2026-11-01"}"#
    }

    func cat(_ f: URL) throws -> JSONObject {
        try JSONParser.parse(try Data(contentsOf: f.appendingPathComponent("catalog.json"))).value.objectValue!
    }

    func write(_ c: JSONObject, _ f: URL) throws {
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: f.appendingPathComponent("catalog.json"))
    }

    /// An adopted binder `tax` with two open items and a spool with an inbox and an outbox; published once unless
    /// `publish` is false.
    func adoptedTax(_ root: URL, publish: Bool = true) throws -> (URL, URL) {
        let f = root.appendingPathComponent("tax", isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let text = #"{"meta":{"schema_version":2,"name":"tax"},"documents":[],"open_items":[\#(item("a-1")),\#(item("a-2"))],"processing_log":[]}"#
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

    func narrowOutside(_ f: URL, to level: String) throws {
        var c = try cat(f)
        var meta = c["meta"]?.objectValue ?? JSONObject()
        meta.set("disclosure", .string(level))
        c.set("meta", .object(meta))
        try write(c, f)
    }

    func slice(_ s: URL) throws -> JSONValue {
        try JSONParser.parse(try Data(contentsOf: s.appendingPathComponent("inbox/tax.agenda.json"))).value
    }

    // 1. A lock another program holds may be a publish that read the wider level: the withdrawal waits for it and
    // the publish fails saying so, instead of reporting a removal that publish could undo. Once the lock is free the
    // withdrawal runs.
    @Test func aWithdrawalWaitsForALockAnotherProgramHolds() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let fd = open(f.appendingPathComponent(".teka.lock").path, O_RDWR | O_CREAT, 0o600)
        #expect(fd >= 0 && flock(fd, LOCK_EX) == 0)
        func publish() throws -> HubLane.PublishResult {
            try HubLane.publish(f, root: s, now: now, force: true, nameCollides: false, lockTimeout: 0.2)
        }
        #expect(throws: TekaStore.Busy.self) { try publish() }
        try narrowOutside(f, to: "none")
        #expect(throws: TekaStore.Refused.self) { try publish() }
        #expect(HubLane.loadCursors(f).sliceHash != nil)
        flock(fd, LOCK_UN)
        close(fd)
        #expect(try publish() == .removed)
        #expect(!FileManager.default.fileExists(atPath: s.appendingPathComponent("inbox/tax.agenda.json").path))
    }

    // 2. A capture list that is not a list keeps the outbox: the completion applies, the acknowledgement refuses,
    // and the file stays byte for byte for repair. So does a completions value that is not a list.
    @Test func aMalformedOutboxIsKeptForRepair() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let outbox = s.appendingPathComponent("outbox/tax.intake.json")
        let body = Data(#"{"completions":[{"id":"tax-a-1","action":"done","at":"2026-10-07T09:00:00Z"}],"items":{"title":"Invented capture"}}"#.utf8)
        try body.write(to: outbox)
        #expect(throws: TekaStore.Refused.self) { try HubLane.drain(f, root: s, now: now) }
        #expect(try cat(f)["open_items"]?.arrayValue?.count == 1)
        #expect(try Data(contentsOf: outbox) == body)

        let bad = Data(#"{"completions":{"id":"tax-a-2","action":"done"}}"#.utf8)
        try bad.write(to: outbox)
        #expect(throws: TekaStore.Refused.self) { try HubLane.acknowledge(file: outbox, applied: [("tax-a-2", nil)]) }
        #expect(try Data(contentsOf: outbox) == bad)
    }

    // 3. Only a publish, under the binder lock, makes the slice key; a drain never does, so it cannot replace the key
    // a publish made meanwhile. An alias still resolves once the key exists.
    @Test func aDrainNeverMakesTheSliceKey() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root, publish: false)
        let outbox = s.appendingPathComponent("outbox/tax.intake.json")
        try Data(#"{"completions":[{"id":"tax-unknown","action":"done"}]}"#.utf8).write(to: outbox)
        #expect(try HubLane.drain(f, root: s, now: now).skipped == 1)
        #expect(!FileManager.default.fileExists(atPath: f.appendingPathComponent(".sprava/slice-key").path))

        guard case .published = try HubLane.publish(f, root: s, now: now) else { Issue.record("publish failed"); return }
        let keyFile = f.appendingPathComponent(".sprava/slice-key")
        let made = try Data(contentsOf: keyFile)
        let key = try #require(try HubLane.existingSliceKey(f))
        let alias = HubLane.alias(.str("a-2"), teka: "tax", key: key)
        try Data(#"{"completions":[{"id":"\#(alias)","action":"done"}]}"#.utf8).write(to: outbox)
        #expect(try HubLane.drain(f, root: s, now: now).applied == 1)
        #expect(try Data(contentsOf: keyFile) == made)
    }

    // 4. A redaction an outside edit added, remembered by the last publish, is not lifted by the person's op when that
    // op was aborted.
    @Test func anAbortedOpDoesNotLiftARetainedRedaction() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        var c = try cat(f)
        var items = c["open_items"]?.arrayValue ?? []
        var first = items[0].objectValue!
        first.set("redact", .bool(true))
        items[0] = .object(first)
        c.set("open_items", .array(items))
        try write(c, f)
        #expect(try HubLane.publish(f, root: s, now: now) == .published(items: 2, overwrittenByOther: false))
        #expect(try slice(s)["items"]?.arrayValue?.first?["title"] == .str("[redacted]"))

        let lines = [
            #"{"id":"op-lift","at":"2026-10-07T10:00:00Z","actor":{"kind":"user"},"op":"update_item","args":{"id":"a-1","unset":["redact"]}}"#,
            #"{"id":"op-abort","at":"2026-10-07T10:00:01Z","actor":{"kind":"import"},"op":"abort","args":{"ops":["op-lift"]}}"#,
        ]
        let log = try FileHandle(forWritingTo: f.appendingPathComponent(".sprava/ops.ndjson"))
        try log.seekToEnd()
        try log.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try log.close()
        first.remove("redact")
        items[0] = .object(first)
        c.set("open_items", .array(items))
        try write(c, f)
        _ = try HubLane.publish(f, root: s, now: now, force: true)
        let firstSlice = try slice(s)["items"]?.arrayValue?.first
        #expect(firstSlice?["title"] == .str("[redacted]"))
        #expect(firstSlice?["id"] != .str("tax-a-1"))
    }

    // 5. A FIFO in the outbox or at the slice never stalls the hub pass: the drain fails at once, and a withdrawal
    // the person asked for still runs; a FIFO at the slice is published over.
    @Test func aFIFOOnTheSpoolDoesNotStallTheHubPass() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let target = s.appendingPathComponent("inbox/tax.agenda.json")
        try FileManager.default.removeItem(at: target)
        #expect(mkfifo(target.path, 0o600) == 0)
        #expect(try HubLane.publish(f, root: s, now: now, force: true) == .published(items: 2, overwrittenByOther: true))

        #expect(mkfifo(s.appendingPathComponent("outbox/tax.intake.json").path, 0o600) == 0)
        try narrowOutside(f, to: "none")
        let out = HubLane.sync(f, root: s, now: now)
        #expect(out.drainError is TekaStore.Refused)
        #expect(out.published == .removed)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    // 6. The outbox's replacement fails when a flush fails: a failed F_FULLFSYNC on a volume that has it, or a folder
    // that cannot be opened after the rename. A volume without F_FULLFSYNC falls back to fsync.
    @Test func aFailedFlushFailsTheReplacement() throws {
        let root = try scratch()
        let file = root.appendingPathComponent("tax.intake.json")
        let old = Data(#"{"completions":[]}"#.utf8)
        try old.write(to: file)
        var eio = HubLane.Flush()
        eio.fullSync = { _ in errno = EIO; return -1 }
        eio.sync = { _ in 0 }
        #expect(throws: AtomicFile.Failure.self) { try HubLane.replace(file, with: Data("{}".utf8), if: { true }, flush: eio) }
        #expect(try Data(contentsOf: file) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["tax.intake.json"])

        var noFolder = HubLane.Flush()
        noFolder.openFolder = { _ in errno = EACCES; return -1 }
        #expect(throws: AtomicFile.Failure.self) { try HubLane.replace(file, with: Data("{}".utf8), if: { true }, flush: noFolder) }

        var unsupported = HubLane.Flush()
        unsupported.fullSync = { _ in errno = ENOTSUP; return -1 }
        #expect(try HubLane.replace(file, with: Data(#"{"a":1}"#.utf8), if: { true }, flush: unsupported))
        #expect(try Data(contentsOf: file) == Data(#"{"a":1}"#.utf8))
    }
}
