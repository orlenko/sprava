import Foundation
@testable import Services
import SpravaKit
import Testing

/// The runtime's own state files, `runtime/breakers.json` and `runtime/state.json`: kept across restarts, never
/// saved over when unreadable, set aside at the start so starting never fails. Temporary folders only.
@Suite struct RuntimeRecordsTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-runtime-\(UUID().uuidString)")
        try AtomicFile.makePrivateFolder(dir)
        return dir
    }

    @Test func breakersSurviveARoundTripAndNothingIsRunningAfterARestart() throws {
        let url = try folder().appendingPathComponent("breakers.json")
        var records = JobRecords()
        var r = JobRecord()
        r.start(at: now)
        r.finish(.error(code: "x", culprit: "y"), at: now, durationMS: 3, threshold: 1)
        r.watchdogExits = 2
        r.running = true
        records.jobs["sentinel"] = r
        try records.save(url)
        let loaded = JobRecords.load(url)
        #expect(loaded.jobs["sentinel"]?.breaker == "open")
        #expect(loaded.jobs["sentinel"]?.watchdogExits == 2)
        #expect(loaded.jobs["sentinel"]?.running == false)
    }

    @Test func unreadableBreakersAreSetAsideAndEveryJobStartsHalfOpen() throws {
        let url = try folder().appendingPathComponent("breakers.json")
        let bad = Data("{\"jobs\": {".utf8)
        try bad.write(to: url)
        let (records, aside) = JobRecords.loadAtStart(url, jobs: ["hub", "sentinel"], now: now)
        let kept = try #require(aside)
        #expect(kept.lastPathComponent.hasPrefix("breakers.json.unreadable-"))
        #expect(try Data(contentsOf: kept) == bad)
        // The recovered half-open records take its place.
        #expect(JobRecords.load(url).jobs["hub"]?.breaker == "half_open")
        #expect(records.jobs["hub"]?.breaker == "half_open" && records.jobs["sentinel"]?.breaker == "half_open")

        // An older file without newer fields keeps its values.
        try Data(#"{"jobs": {"hub": {"breaker": "open", "breakerOpenedAt": "2026-10-01T10:00:00Z", "consecutiveFailures": 4}}}"#.utf8).write(to: url)
        let (old, none) = JobRecords.loadAtStart(url, jobs: ["hub"], now: now)
        #expect(none == nil)
        #expect(old.jobs["hub"]?.breaker == "open" && old.jobs["hub"]?.consecutiveFailures == 4)
    }

    @Test func anOutOfRangeBreakerIsSetAsideAtStart() throws {
        let url = try folder().appendingPathComponent("breakers.json")
        for bad in [#""breaker":"open","breakerOpenedAt":"2026-10-06T08:00:00Z","backoffStep":-1"#,
                    #""breaker":"open","breakerOpenedAt":"2026-10-06T08:00:00Z","backoffStep":9"#,
                    #""breaker":"open""#, #""breaker":"ajar""#, #""consecutiveFailures":-3"#] {
            try Data(#"{"jobs":{"hub":{\#(bad)}}}"#.utf8).write(to: url)
            let (records, aside) = JobRecords.loadAtStart(url, jobs: ["hub", "capture"], now: now)
            let kept = try #require(aside, "\(bad)")
            #expect(FileManager.default.fileExists(atPath: kept.path))
            #expect(records.jobs["hub"]?.breaker == "half_open" && records.jobs["capture"]?.breaker == "half_open")
            try FileManager.default.removeItem(at: kept)
        }
    }

    @Test func recordsTheHeartbeatWouldRefuseOrThatCouldOverflowAreSetAside() throws {
        let url = try folder().appendingPathComponent("breakers.json")
        for bad in [#""lastOutcome":"bogus""#, #""consecutiveFailures":\#(Int.max)"#, #""watchdogExits":2000000"#,
                    #""lastErrorCode":"Not A Code""#, #""durationsMS":[-5]"#] {
            try Data(#"{"jobs":{"hub":{\#(bad)}}}"#.utf8).write(to: url)
            #expect(throws: StateFile.Unreadable.self, "\(bad)") { try JobRecords.read(url) }
        }
    }

    @Test func aFileTheStartCouldNotSetAsideIsNeverSavedOver() throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("breakers.json")
        let bad = Data("{\"jobs\": {".utf8)
        try bad.write(to: url)
        // The set-aside name is taken, so the rename fails and the file stays where it is.
        let stamp = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!).replacingOccurrences(of: ":", with: "")
        try Data("taken".utf8).write(to: dir.appendingPathComponent("breakers.json.unreadable-" + stamp))
        let (records, aside) = JobRecords.loadAtStart(url, jobs: ["hub"], now: now)
        #expect(aside == nil)
        #expect(throws: (any Error).self) { try records.save(url) }
        #expect(try Data(contentsOf: url) == bad)
    }

    @Test func aLinkInPlaceOfTheBreakersIsMovedAsideNotFollowed() throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("breakers.json"), elsewhere = dir.appendingPathComponent("elsewhere.json")
        var records = JobRecords()
        records.jobs["hub"] = JobRecord()
        try records.save(elsewhere)
        let original = try Data(contentsOf: elsewhere)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
        #expect(throws: StateFile.Unreadable.self) { try JobRecords.read(url) }
        JobRecords.recordWatchdogExit(job: "hub", threshold: 3, url: url, now: now)
        #expect(try Data(contentsOf: elsewhere) == original)
        let (_, aside) = JobRecords.loadAtStart(url, jobs: ["hub"], now: now)
        let kept = try #require(aside)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: kept.path) == elsewhere.path)
        #expect(try Data(contentsOf: elsewhere) == original)
    }

    @Test func aLinkedRuntimeFolderIsNeverReachedThroughBySettingAside() throws {
        let base = try folder()
        let real = base.appendingPathComponent("elsewhere"), runtime = base.appendingPathComponent("runtime")
        try AtomicFile.makePrivateFolder(real)
        try Data("{\"jobs\": {".utf8).write(to: real.appendingPathComponent("breakers.json"))
        try Data("{\"day\": 7".utf8).write(to: real.appendingPathComponent("state.json"))
        try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: real)
        #expect(JobRecords.loadAtStart(runtime.appendingPathComponent("breakers.json"), jobs: ["hub"], now: now).setAside == nil)
        #expect(RuntimeState.loadAtStart(runtime, now: now).setAside == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).sorted() == ["breakers.json", "state.json"])
    }

    @Test func aCountNoDayCanReachIsSetAsideNotTrappedOn() throws {
        let dir = try folder()
        try Data(#"{"day":"\#(CalendarDate.today().description)","startsToday":\#(Int.max)}"#.utf8).write(to: RuntimeState.url(dir))
        #expect(throws: StateFile.Unreadable.self) { try RuntimeState.read(dir) }
        #expect(!RuntimeState.recordStart(dir))
        #expect(RuntimeState.loadAtStart(dir, now: now).setAside != nil)
    }

    @Test func theRecoveredBreakersAreSavedSoAnEarlyWedgeFindsThemHalfOpen() throws {
        let url = try folder().appendingPathComponent("breakers.json")
        try Data("{\"jobs\": {".utf8).write(to: url)
        _ = JobRecords.loadAtStart(url, jobs: ["hub"], now: now)
        JobRecords.recordWatchdogExit(job: "hub", threshold: 3, url: url, now: now)
        #expect(JobRecords.load(url).jobs["hub"]?.breaker == "open")
    }

    @Test func aWedgeOnAnOpenBreakerStartsItsBackoffAgain() {
        var r = JobRecord()
        r.finish(.timeout, at: now, durationMS: 1, threshold: 1)
        #expect(r.breaker == "open" && r.backoffStep == 0)
        let later = now.addingTimeInterval(900)
        r.recordWatchdogExit(at: later, threshold: 1)
        #expect(r.breaker == "open" && r.breakerOpenedAt == later && r.backoffStep == 1)
        let early = r.mayRun(now: later.addingTimeInterval(60))
        #expect(!early)
    }

    @Test func countsStopAtTheLimitSoTheFileAlwaysReadsBack() throws {
        let dir = try folder()
        let today = CalendarDate.today().description
        try Data(#"{"day":"\#(today)","startsToday":\#(RuntimeState.maxCount)}"#.utf8).write(to: RuntimeState.url(dir))
        #expect(RuntimeState.recordStart(dir))
        #expect(try RuntimeState.read(dir).startsToday == RuntimeState.maxCount)
    }

    @Test func theStateLockIsNeverOpenedThroughALinkedFolder() throws {
        let base = try folder()
        let real = base.appendingPathComponent("elsewhere"), runtime = base.appendingPathComponent("runtime")
        try AtomicFile.makePrivateFolder(real)
        try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: real)
        #expect(!RuntimeState.recordRefusal(runtime))
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
    }

    @Test func twoWatchdogExitsOpenTheBreaker() throws {
        let url = try folder().appendingPathComponent("breakers.json")
        JobRecords.recordWatchdogExit(job: "hub", threshold: 3, url: url, now: now)
        #expect(JobRecords.load(url).jobs["hub"]?.breaker == "closed")
        JobRecords.recordWatchdogExit(job: "hub", threshold: 3, url: url, now: now)
        var record = try #require(JobRecords.load(url).jobs["hub"])
        #expect(record.breaker == "open")
        let mayRun = record.mayRun(now: now.addingTimeInterval(30))
        #expect(!mayRun)
        record.finish(.ok, at: now, durationMS: 1, threshold: 3)
        #expect(record.watchdogExits == 0)
    }

    @Test func unreadableRuntimeStateIsSetAsideAndNeverRepeatsTheSummary() throws {
        let dir = try folder()
        let url = RuntimeState.url(dir)
        let garbage = Data("{\"day\": 7".utf8)
        try garbage.write(to: url)
        #expect(throws: StateFile.Unreadable.self) { try RuntimeState.read(dir) }
        // A change before the start (a lease refusal) is dropped, never saved over the file.
        #expect(!RuntimeState.recordRefusal(dir))
        #expect(try Data(contentsOf: url) == garbage)

        let (state, aside) = RuntimeState.loadAtStart(dir, now: now)
        let kept = try #require(aside)
        #expect(try Data(contentsOf: kept) == garbage)
        let today = CalendarDate.today(now: now).description
        #expect(state.lastSummaryDate == today && state.startsToday == 0)
        // The recovered state was saved, so counting starts again and today's summary still counts as sent.
        #expect(RuntimeState.recordStart(dir))
        // (recordStart counts on the real day; the marker is the test's day.)
        let after = try RuntimeState.read(dir)
        #expect(after.startsToday == 1 && after.lastSummaryDate == today)
        // A file from before a field existed still reads.
        try Data(#"{"day":"2026-10-06","startsToday":2}"#.utf8).write(to: url)
        #expect(try RuntimeState.read(dir, today: "2026-10-06").startsToday == 2)
        // A new day resets today's counters.
        #expect(try RuntimeState.read(dir, today: "2026-10-07").startsToday == 0)
    }
}
