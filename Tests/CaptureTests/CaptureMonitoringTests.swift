import BinderStore
@testable import Capture
import Foundation
import SpravaKit
import Testing

@Suite struct CaptureMonitoringTests {
    func setup() throws -> (URL, CaptureInbox) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-monitor-\(UUID().uuidString)")
        let support = base.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return (base, CaptureInbox(root: base.appendingPathComponent("captures"), support: support))
    }

    @Test func healthRetainsVerifiedCardCountsAndOldestAge() throws {
        let (base, inbox) = try setup()
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date(timeIntervalSince1970: 1_791_360_000)
        let card = Proposal.make(title: "Invented reminder", actor: JSONObject(), ops: [], now: now.addingTimeInterval(-120))
        try inbox.writeUnfiled(card.raw)
        let quarantine = inbox.support.appendingPathComponent("capture/quarantine/device")
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data("invented failure".utf8).write(to: quarantine.appendingPathComponent("event.why"))
        let health = inbox.health(now: now)
        #expect(health.error == nil && health.unfiled == 1 && health.quarantined == 1)
        #expect(health.oldestUnfiledSeconds == 120)
        #expect(try inbox.boundedUnfiled().map(\.id) == [card.id])
    }

    @Test func tooManyUnfiledEntriesFailMonitoringWithoutDeletingAnything() throws {
        let (base, inbox) = try setup()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: inbox.unfiledDir, withIntermediateDirectories: true)
        for n in 0..<101 { try Data().write(to: inbox.unfiledDir.appendingPathComponent("invented-\(n)")) }
        #expect(throws: CaptureInbox.MonitoringError.self) { try inbox.boundedUnfiled() }
        #expect(inbox.health().error != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.unfiledDir.path).count == 101)
    }

    @Test func quarantineCountsUseABoundedStreamingWalk() throws {
        let (base, inbox) = try setup()
        defer { try? FileManager.default.removeItem(at: base) }
        let quarantine = inbox.support.appendingPathComponent("capture/quarantine")
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        for n in 0..<1_001 { try Data().write(to: quarantine.appendingPathComponent("invented-\(n).why")) }
        #expect(inbox.health().error != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count == 1_001)
    }

    @Test func aSparseOversizedJournalIsRefusedBeforeReadingIt() throws {
        let (base, inbox) = try setup()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: inbox.support.appendingPathComponent("capture"), withIntermediateDirectories: true)
        try Data().write(to: inbox.journalURL)
        let file = try FileHandle(forWritingTo: inbox.journalURL)
        try file.truncate(atOffset: 1 << 30)
        try file.close()
        #expect(throws: CaptureInbox.MonitoringError.self) { try inbox.measurementInput() }
        #expect(try inbox.journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == 1 << 30)
    }

    @Test func journalFIFOsAndLinksNeverBlockMonitoring() throws {
        let (base, inbox) = try setup()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: inbox.support.appendingPathComponent("capture"), withIntermediateDirectories: true)
        #expect(mkfifo(inbox.journalURL.path, 0o600) == 0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            #expect(throws: CaptureInbox.MonitoringError.self) { try inbox.measurementInput() }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 10) == .success)
        try FileManager.default.removeItem(at: inbox.journalURL)
        try FileManager.default.createSymbolicLink(at: inbox.journalURL, withDestinationURL: base.appendingPathComponent("missing"))
        #expect(throws: CaptureInbox.MonitoringError.self) { try inbox.measurementInput() }
    }

    @Test func tooManySmallJournalRecordsFailBeforeReporting() throws {
        let (base, inbox) = try setup()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: inbox.support.appendingPathComponent("capture"), withIntermediateDirectories: true)
        try Data(String(repeating: "{}\n", count: 10_001).utf8).write(to: inbox.journalURL)
        #expect(throws: CaptureInbox.MonitoringError.self) { try inbox.measurementInput() }
        #expect(try Data(contentsOf: inbox.journalURL).count == 30_003)
    }

    @Test func measurementInputsKeepJournalEventsAndVerifiedCards() throws {
        let (base, inbox) = try setup()
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date(timeIntervalSince1970: 1_791_360_000)
        let device = "0f0e0d0c-0b0a-4908-8706-050403020100"
        try inbox.registerProducer(folder: device, app: "sprava")
        let producer = CaptureProducer(root: inbox.root, deviceID: device, support: inbox.support)
        let (event, digest) = try producer.writeNote("Invented capture", startedAt: now, savedAt: now)
        let id = try #require(event["id"]?.stringValue)
        try inbox.recordNotice(event: id, digest: digest, now: now)
        _ = inbox.sweep(binders: [], commands: Commands(support: inbox.support, deviceID: "dev"), now: now)
        let input = try inbox.measurementInput()
        #expect(input.journal.contains { $0["event"] == .string(id) && $0["stage"] == .str("ingested") })
        #expect(input.events[id]?.raw == event)
        #expect(input.unfiled.count == 1)
    }

    @Test func measurementSourcePathsCannotFollowADeviceLink() throws {
        let (base, inbox) = try setup()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: inbox.root.appendingPathComponent("device"), withDestinationURL: outside)
        let bytes = Data("{}".utf8)
        try bytes.write(to: outside.appendingPathComponent("event.json"))
        var state = CaptureInbox.State()
        state.paths = ["invented": "device/event.json"]
        try inbox.save(state)
        try Data("{\"stage\":\"ingested\",\"event\":\"invented\"}\n".utf8).write(to: inbox.journalURL)
        #expect(throws: Error.self) { try inbox.measurementInput() }
        #expect(try Data(contentsOf: outside.appendingPathComponent("event.json")) == bytes)
    }

    @Test func aggregateCaptureSourceBytesAreBoundedBeforeRetention() throws {
        let (base, inbox) = try setup()
        defer { try? FileManager.default.removeItem(at: base) }
        let device = inbox.root.appendingPathComponent("device")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let bytes = Data(("{\"invented\":\"" + String(repeating: "x", count: 4 << 20) + "\"}").utf8)
        var state = CaptureInbox.State()
        state.paths = ["first": "device/first.json", "second": "device/second.json"]
        try inbox.save(state)
        for name in ["first", "second"] { try bytes.write(to: device.appendingPathComponent("\(name).json")) }
        let journal = "{\"stage\":\"ingested\",\"event\":\"first\"}\n{\"stage\":\"ingested\",\"event\":\"second\"}\n"
        try Data(journal.utf8).write(to: inbox.journalURL)
        #expect(throws: CaptureInbox.MonitoringError.self) { try inbox.measurementInput() }
        #expect(try Data(contentsOf: device.appendingPathComponent("first.json")) == bytes)
    }
}
