import BinderFormat
import BinderStore
import Capture
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The shadow run's measures (mvp.md 1.2), counted from Sprava's own records: counts only. Invented data only.
@Suite(.serialized) struct MeasuresTests {
    @Test func anOversizedCaptureJournalMakesTheReportUnavailable() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-measures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("capture"), withIntermediateDirectories: true)
        let file = support.appendingPathComponent("capture/journal.ndjson")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        let day = CalendarDate.today()
        let report = Measures(support: support).compute(rows: [], from: day, to: day)
        #expect(report.error != nil)
        #expect(Measures.text(report).hasPrefix("Report unavailable:"))
        #expect(!Measures.text(report).contains("(pass)"))
        #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == 1 << 30)
    }

    @Test func aFIFOAtTheJobLogFailsTheReportWithoutWaiting() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-measures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        #expect(mkfifo(support.appendingPathComponent("runtime/jobs.log").path, 0o600) == 0)
        final class Box: @unchecked Sendable { var report: Measures.Report? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let day = CalendarDate.today()
        Thread.detachNewThread {
            box.report = Measures(support: support).compute(rows: [], from: day, to: day)
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(box.report?.error != nil)
    }

    @Test func aHugeRequestedWindowIsRefusedBeforeAllocatingIt() {
        let day = CalendarDate.today()
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-measures-\(UUID().uuidString)")
        let report = Measures(support: support).compute(rows: [], from: day.adding(days: -100_000), to: day)
        #expect(report.error != nil)
        #expect(Measures.text(report).hasPrefix("Report unavailable:"))
    }

    @Test func anOverBudgetCardDirectoryDoesNotProduceAPassingReport() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-measures-\(UUID().uuidString)")
        let folder = try makeTeka(fixture: "sprava-v0")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: support) }
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: Date())
        let cards = folder.appendingPathComponent(".sprava/proposals")
        try FileManager.default.createDirectory(at: cards, withIntermediateDirectories: true)
        for n in 0..<101 { try Data().write(to: cards.appendingPathComponent("invented-\(n)")) }
        let day = CalendarDate.today()
        let report = Measures(support: support).compute(rows: Shelf.rows(registry: nil, picked: [folder]), from: day, to: day)
        #expect(report.error != nil)
        #expect(!Measures.text(report).contains("(pass)"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cards.path).count == 101)
    }

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

    /// A FIFO standing where the history lives is never read: the measures come back without waiting on it.
    @Test func aFIFOAtTheHistoryIsNotWaitedOn() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-measures-\(UUID().uuidString)")
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: Date())
        let log = folder.appendingPathComponent(".sprava/ops.ndjson")
        try FileManager.default.removeItem(at: log)
        #expect(mkfifo(log.path, 0o600) == 0)
        let rows = [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))]
        #expect(rows[0].teka.writesBlocked)
        final class Box: @unchecked Sendable { var report: Measures.Report? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let today = CalendarDate.today()
        Thread.detachNewThread {
            box.report = Measures(support: support).compute(rows: rows, from: today.adding(days: -1), to: today)
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(box.report?.externalEdits.isEmpty == true)
    }
}
