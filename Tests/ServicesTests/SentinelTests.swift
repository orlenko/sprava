import BinderFormat
import BinderStore
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The deadline sentinel's record: counts per binder under opaque ids, never titles (architecture 3.4, 3.7), and
/// the Shelf as a job reads it. Invented data only.
@Suite struct SentinelTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-sentinel-\(UUID().uuidString)", isDirectory: true)
        try AtomicFile.makePrivateFolder(url)
        return url
    }

    @Test func countsUnderOpaqueIDsWithNoTitles() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        let rows = Shelf.rows(registry: nil, picked: [folder])
        var ids = BinderIDs()
        let report = SentinelReport.compute(rows: rows, ids: &ids, today: today, now: Date(), timeZone: utc)
        #expect(report.binders["b1"] == SentinelReport.Counts(state: "ready", overdue: 0, today: 0, nudge: 1, next7: 1))
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains("estate"))
        #expect(!json.contains("notary"))
        #expect(report.summaryText == "1 to follow up")
        #expect(ids.id(for: folder) == "b1")
        #expect(ids.id(for: folder.appendingPathComponent("../other")) == "b2")
    }

    @Test func binderIDsAreNeverReassignedOverAnUnreadableFile() throws {
        let url = try folder().appendingPathComponent("binder-ids.json")
        #expect(try BinderIDs.load(url).byPath.isEmpty)
        var ids = BinderIDs()
        _ = ids.id(for: URL(fileURLWithPath: "/Invented/binder-a", isDirectory: true))
        try ids.save(url)
        #expect(try BinderIDs.load(url).byPath.values.sorted() == ["b1"])
        try Data("{\"byPath\": ".utf8).write(to: url)
        #expect(throws: BinderIDs.Unreadable.self) { _ = try BinderIDs.load(url) }
    }

    @Test func theSummaryRespectsTheSentinelBreaker() {
        #expect(SummaryFallback.decide(reportFresh: true, sentinelBreaker: "open") == .useReport)
        #expect(SummaryFallback.decide(reportFresh: false, sentinelBreaker: "open") == .stale)
        #expect(SummaryFallback.decide(reportFresh: false, sentinelBreaker: "half_open") == .runSentinel)
        #expect(SummaryFallback.decide(reportFresh: false, sentinelBreaker: nil) == .runSentinel)
    }

    @Test func jobsSeeAnUnreadableShelf() throws {
        let store = ShelfStore(supportDirectory: try folder())
        #expect(try store.rowsForJobs().isEmpty)
        try Data("{ not json".utf8).write(to: store.file)
        #expect(throws: ShelfStore.Unreadable.self) { _ = try store.rowsForJobs() }
    }
}
