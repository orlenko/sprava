import BinderFormat
import BinderStore
import Foundation
import Hub
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The doctor's findings for the binders this Mac owns. Invented data only.
@Suite(.serialized) struct DoctorTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    @Test func theDoctorAsksForTheAddendum() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-doctor-\(UUID().uuidString)")
        let device = try #require(Owner.device(of: folder))
        try Data("# Manual\nRun lifeproj publish after each digest.\n".utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        var findings = Doctor.run(rows: Shelf.rows(registry: nil, picked: [folder]), deviceID: device, registry: nil,
                                  support: support, spool: support)
        #expect(findings.contains { $0.level == .fix && $0.text.contains("addendum") })
        try Data(("# Manual\n" + ManualAddendum.text).utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        findings = Doctor.run(rows: Shelf.rows(registry: nil, picked: [folder]), deviceID: device, registry: nil,
                              support: support, spool: support)
        #expect(!findings.contains { $0.text.contains("addendum") })
    }

    /// A FIFO in the binder or the spool is reported, never waited on (from the local review of the readers).
    @Test func aFIFOAtTheDashboardIsReportedNotWaitedOn() throws {
        let (folder, support, device) = try adoptedBinder()
        try makeFIFO(folder.appendingPathComponent("DASHBOARD.md"))
        let findings = try doctorReturns(folder: folder, support: support, device: device)
        #expect(findings.contains { $0.level == .fix && $0.text == "DASHBOARD.md cannot be read (not a plain file)" })
    }

    @Test func aFIFOAtTheHistoryIsReportedNotWaitedOn() throws {
        let (folder, support, device) = try adoptedBinder()
        try makeFIFO(folder.appendingPathComponent(".sprava/ops.ndjson"))
        let findings = try doctorReturns(folder: folder, support: support, device: device)
        #expect(findings.contains { $0.level == .fix && $0.text.contains(".sprava/ops.ndjson is not a regular file") })
    }

    @Test func aFIFOAtTheSliceOnTheHubIsReportedNotWaitedOn() throws {
        let (folder, support, device) = try adoptedBinder()
        let inbox = support.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try makeFIFO(inbox.appendingPathComponent("estate-example.agenda.json"))
        let findings = try doctorReturns(folder: folder, support: support, device: device)
        #expect(findings.contains { $0.level == .fix && $0.text.contains("slice on the hub cannot be read") })
    }

    /// A history too large to load (here a sparse file of a gigabyte) is reported, never read whole.
    @Test func anOversizedHistoryIsReportedNotRead() throws {
        let (folder, support, device) = try adoptedBinder()
        let log = folder.appendingPathComponent(".sprava/ops.ndjson")
        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        #expect(!OpLogBound.fits(folder))
        let findings = try doctorReturns(folder: folder, support: support, device: device)
        #expect(findings.contains { $0.level == .fix && $0.text.contains("history is larger than 64 MB") }, "\(findings)")
        try FileManager.default.removeItem(at: folder)
    }

    private func adoptedBinder() throws -> (URL, URL, String) {
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-doctor-\(UUID().uuidString)")
        return (folder, support, try #require(Owner.device(of: folder)))
    }

    private func editCatalog(_ folder: URL, edit: (inout JSONObject) -> Void) throws {
        let file = folder.appendingPathComponent("catalog.json")
        var value = try #require(try JSONParser.parse(Data(contentsOf: file)).value.objectValue)
        edit(&value)
        try Data(JSONWriter.pretty(.object(value)).utf8).write(to: file)
    }

    @Test func itemRedactionAtFullDisclosureAlarmsForEitherMac() throws {
        let (folder, support, device) = try adoptedBinder()
        try TekaStore(folder: folder).apply([.init(op: "set_disclosure", args: .init([(key: "disclosure", value: .str("full"))]),
                                                  actor: .init([(key: "kind", value: .str("user"))]))], now: now)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        guard case .published = try HubLane.publish(folder, root: support, now: now) else {
            throw TekaStore.Refused(reason: "the invented test binder did not publish")
        }
        let slice = support.appendingPathComponent("inbox/estate-example.agenda.json")
        let before = try Data(contentsOf: slice)
        try editCatalog(folder) { value in
            var items = value["open_items"]!.arrayValue!
            var item = items[0].objectValue!
            item.set("redact", .bool(true))
            items[0] = .object(item)
            value.set("open_items", .array(items))
        }
        for id in [Optional(device), nil] {
            let findings = Doctor.run(rows: Shelf.rows(registry: nil, picked: [folder]), deviceID: id,
                                      registry: nil, support: support, spool: support)
            #expect(findings.contains { $0.level == .fix && $0.text.contains("shows more than its current privacy allows") })
        }
        #expect(try Data(contentsOf: slice) == before)
    }

    @Test func lifeprojCoexistenceWarnsAboutItemWideningAtFullDisclosure() throws {
        let (folder, support, device) = try adoptedBinder()
        try TekaStore(folder: folder).apply([.init(op: "set_disclosure", args: .init([(key: "disclosure", value: .str("full"))]),
                                                  actor: .init([(key: "kind", value: .str("user"))]))], now: now)
        try editCatalog(folder) { value in
            var items = value["open_items"]!.arrayValue!
            let index = items.firstIndex { $0["redact"] == .bool(true) }!
            var item = items[index].objectValue!
            item.remove("redact")
            item.remove("kind")
            item.set("slice_title", .str("Invented outside label"))
            items[index] = .object(item)
            value.set("open_items", .array(items))
        }
        let registry = LifeprojRegistry.parse("[projects.invented]\nworking_dir = '\(folder.path)'\n")
        for id in [Optional(device), nil] {
            let findings = Doctor.run(rows: Shelf.rows(registry: nil, picked: [folder]), deviceID: id,
                                      registry: registry, support: support)
            #expect(findings.contains { $0.text.contains("pending item privacy changes are not enforced") })
        }
    }

    @Test func invalidHistoryNeverMakesAResidualSliceSafeForEitherMac() throws {
        let (folder, support, device) = try adoptedBinder()
        try TekaStore(folder: folder).apply([.init(op: "set_disclosure", args: .init([(key: "disclosure", value: .str("none"))]),
                                                  actor: .init([(key: "kind", value: .str("user"))]))], now: now)
        try editCatalog(folder) { value in
            var meta = value["meta"]!.objectValue!
            meta.set("disclosure", .str("full"))
            value.set("meta", .object(meta))
        }
        var log = try TekaStore(folder: folder).readOpLog().ops
        log.append(.init([(key: "id", value: .str("invented-invalid-op")), (key: "op", value: .str("set_disclosure")),
                          (key: "args", value: .obj([("disclosure", .str("full"))])),
                          (key: "actor", value: .obj([("kind", .str("user"))])),
                          (key: "before_hash", value: log.last!["after_hash"]!), (key: "after_hash", value: .str("invalid"))]))
        let history = folder.appendingPathComponent(".sprava/ops.ndjson")
        let bytes = Data(log.map { JSONWriter.compact(.object($0)) + "\n" }.joined().utf8)
        try bytes.write(to: history)
        let inbox = support.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: inbox.appendingPathComponent("estate-example.agenda.json"))
        for id in [Optional(device), nil] {
            let findings = Doctor.run(rows: Shelf.rows(registry: nil, picked: [folder]), deviceID: id,
                                      registry: nil, support: support, spool: support)
            #expect(findings.contains { $0.text.contains("could not confirm its approved disclosure") })
        }
        #expect(try Data(contentsOf: history) == bytes)
    }

    @Test func aResidualHubSliceAtNoneIsAPrivacyFinding() throws {
        let (folder, support, device) = try adoptedBinder()
        try TekaStore(folder: folder).apply([.init(op: "set_disclosure", args: JSONObject([(key: "disclosure", value: .str("none"))]),
            actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        let inbox = support.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let slice = inbox.appendingPathComponent("estate-example.agenda.json")
        try Data("{}".utf8).write(to: slice)
        let findings = try doctorReturns(folder: folder, support: support, device: device)
        #expect(findings.contains { $0.level == .fix && $0.text == "this binder's disclosure is none, but its slice is still on the hub" })
        let migrated = Doctor.run(rows: Shelf.rows(registry: nil, picked: [folder]), deviceID: "replacement-mac", registry: nil,
                                  support: support, spool: support)
        #expect(migrated.contains { $0.text.contains("managed by another Mac") })
        #expect(migrated.contains { $0.level == .fix && $0.text == "this binder's disclosure is none, but its slice is still on the hub" })
        #expect(try Data(contentsOf: slice) == Data("{}".utf8))
        // An outside widening still leaves the approved level at none; the old slice must keep alarming.
        let catalogFile = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(Teka.read(folder).catalog)
        var meta = try #require(catalog["meta"]?.objectValue)
        meta.set("disclosure", .str("full"))
        catalog.set("meta", .object(meta))
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: catalogFile)
        let widened = try doctorReturns(folder: folder, support: support, device: device)
        #expect(widened.contains { $0.level == .fix && $0.text == "this binder's disclosure is none, but its slice is still on the hub" })
        let migratedWidened = Doctor.run(rows: Shelf.rows(registry: nil, picked: [folder]), deviceID: "replacement-mac", registry: nil,
                                         support: support, spool: support)
        #expect(migratedWidened.contains { $0.level == .fix && $0.text == "this binder's disclosure is none, but its slice is still on the hub" })
        try FileManager.default.removeItem(at: slice)
        try makeFIFO(slice)
        let unreadable = try doctorReturns(folder: folder, support: support, device: device)
        #expect(unreadable.contains { $0.level == .fix && $0.text.contains("slice on the hub cannot be read") })
    }

    @Test func anOverBudgetCaptureHealthSnapshotIsReported() throws {
        let (_, support, device) = try adoptedBinder()
        let unfiled = support.appendingPathComponent("unfiled")
        try FileManager.default.createDirectory(at: unfiled, withIntermediateDirectories: true)
        for n in 0..<101 { try Data().write(to: unfiled.appendingPathComponent("invented-\(n)")) }
        let findings = Doctor.run(rows: [], deviceID: device, registry: nil, support: support, spool: support)
        #expect(findings.contains { $0.level == .fix && $0.text.contains("capture records cannot be checked") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: unfiled.path).count == 101)
    }

    @Test func everyNonFullMVPDisclosureAlarmsOnAResidualSlice() throws {
        let (folder, support, device) = try adoptedBinder()
        let inbox = support.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let slice = inbox.appendingPathComponent("estate-example.agenda.json")
        let bytes = Data("{}".utf8)
        try bytes.write(to: slice)
        for level in ["kind", "title", "none"] {
            try TekaStore(folder: folder).apply([.init(op: "set_disclosure", args: JSONObject([(key: "disclosure", value: .string(level))]),
                actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
            let findings = try doctorReturns(folder: folder, support: support, device: device)
            #expect(findings.contains { $0.level == .fix && $0.text == "this binder's disclosure is \(level), but its slice is still on the hub" })
            #expect(try Data(contentsOf: slice) == bytes)
        }
    }

    @Test func coexistenceUsesApprovedDisclosureEvenAfterOutsideWidening() throws {
        let (folder, support, device) = try adoptedBinder()
        let store = TekaStore(folder: folder)
        try store.apply([.init(op: "set_disclosure", args: JSONObject([(key: "disclosure", value: .str("kind"))]),
                               actor: JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))]))], now: now)
        let file = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: file)).value.objectValue)
        var meta = try #require(catalog["meta"]?.objectValue)
        meta.set("disclosure", .str("full"))
        catalog.set("meta", .object(meta))
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: file)
        let registry = LifeprojRegistry.parse("[projects.invented]\nworking_dir = '\(folder.path)'\n")
        let findings = Doctor.run(rows: Shelf.rows(registry: nil, picked: [folder]), deviceID: device, registry: registry,
                                  support: support, spool: support)
        #expect(findings.contains { $0.text == "lifeproj can still reach this binder, so its disclosure kind is not enforced there" })
    }

    @Test func coexistenceRecognizesBothSpellingsOfAnAliasedBinder() throws {
        let (folder, support, device) = try adoptedBinder()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let alias = support.appendingPathComponent("binder-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        for (picked, registered) in [(folder, alias), (alias, folder)] {
            let registry = LifeprojRegistry.parse("[projects.invented]\nworking_dir = '\(registered.path)'\n")
            let findings = Doctor.run(rows: Shelf.rows(registry: nil, picked: [picked]), deviceID: device, registry: registry,
                                      support: support, spool: support)
            #expect(findings.contains { $0.text.contains("lifeproj can still reach this binder") })
        }
    }

    @Test func longValidHistoryIsReportedWithoutReplayOrChangingFiles() throws {
        let (folder, support, device) = try adoptedBinder()
        let file = folder.appendingPathComponent(".sprava/ops.ndjson")
        var log = try TekaStore(folder: folder).readOpLog().ops
        let hash = try #require(log.last?["after_hash"]?.stringValue)
        for index in 0..<100 {
            log.append(JSONObject([(key: "id", value: .str("invented-\(index)")), (key: "op", value: .str("expunge")),
                                   (key: "at", value: .str(ISOTime.string(now))), (key: "args", value: .object(JSONObject())),
                                   (key: "before_hash", value: .str(hash)), (key: "after_hash", value: .str(hash))]))
        }
        // The long log is valid; Health refuses work rather than treating it as corrupt.
        #expect(try Canonical.hash(.object(Replay.run(log))) == hash)
        let data = Data((log.map { JSONWriter.compact(.object($0)) }.joined(separator: "\n") + "\n").utf8)
        try data.write(to: file)
        let findings = try doctorReturns(folder: folder, support: support, device: device)
        #expect(findings.contains { $0.level == .note && $0.text == DoctorReplayBudget.finding })
        #expect(!findings.contains { $0.text.contains("history does not replay") })
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func historyBudgetCountsAggregateWorkAndPatchSteps() {
        let op = JSONObject([(key: "op", value: .str("expunge"))])
        #expect(DoctorReplayBudget.fits([op], bytes: 1 << 20))
        #expect(!DoctorReplayBudget.fits(Array(repeating: op, count: 5), bytes: 1 << 20))
        let patch = JSONObject([(key: "args", value: .obj([("patch", .array(Array(repeating: .null, count: 500)))]))])
        #expect(!DoctorReplayBudget.fits([patch], bytes: 1))
    }

    @Test func historyOverTheInputBudgetIsPreservedAndOtherChecksStillRun() throws {
        let (folder, support, device) = try adoptedBinder()
        let file = folder.appendingPathComponent(".sprava/ops.ndjson")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 2 << 20)
        try handle.close()
        let registry = LifeprojRegistry.parse("[projects.invented]\nworking_dir = '\(folder.path)'\n")
        let findings = Doctor.run(rows: Shelf.rows(registry: nil, picked: [folder]), deviceID: device, registry: registry,
                                  support: support, spool: support)
        #expect(findings.contains { $0.text == DoctorReplayBudget.finding })
        #expect(findings.contains { $0.text.contains("lifeproj can still reach this binder") })
        #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == 2 << 20)
    }

    private func makeFIFO(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard mkfifo(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Runs the doctor off the test's thread, so a read that waits on a FIFO fails the test instead of hanging it.
    private func doctorReturns(folder: URL, support: URL, device: String) throws -> [Doctor.Finding] {
        final class Box: @unchecked Sendable { var findings: [Doctor.Finding]? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let rows = Shelf.rows(registry: nil, picked: [folder])
        Thread.detachNewThread {
            box.findings = Doctor.run(rows: rows, deviceID: device, registry: nil, support: support, spool: support)
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else { Issue.record("the doctor waited on a FIFO"); return [] }
        return try #require(box.findings)
    }
}
