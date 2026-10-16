import BinderFormat
import Foundation
import Shelf
import Services
@testable import SpravaApp
import SpravaKit
import SpravaTestSupport
import Testing

// The screens' models, against a stand-in runtime: no test talks to a real runtime over XPC, and every folder is a
// temporary one with invented content.

/// Answers requests by command name with a JSON text, or refuses the ones it has no answer for, and records them.
/// `ping` is answered while it runs and counted apart; when it does not run, every request fails as a connection to
/// no runtime does.
@MainActor
final class StandInRuntime {
    var answers: [String: @MainActor (JSONValue) async -> String] = [:]
    var sent: [JSONValue] = []
    var pings = 0
    var running = true

    // Holds the stand-in strongly: a test may keep only the client.
    lazy var client = RuntimeClient(answer: { [self] text in
        let request = try JSONParser.parse(text).value
        let name = request["command"]?.stringValue
        if name == "ping" { pings += 1 } else { sent.append(request) }
        guard running else {
            throw RuntimeClient.Failure.notRunning(NSError(domain: NSCocoaErrorDomain, code: 4099,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't communicate with a helper application."]))
        }
        if name == "ping" { return #"{"ok":true,"protocol":1}"# }
        guard let name, let answer = answers[name] else { return #"{"ok":false,"error":"refused by the stand-in"}"# }
        return await answer(request)
    })
}

func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-app-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Disk-read bounds that expire only when the test says so: a read is late because the test made it late, never
/// because the machine is busy. A bound never expired never ends its read early.
final class ManualDeadlines: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []

    var deadline: DiskDeadline { { [self] _, expire in lock.withLock { pending.append(expire) } } }

    /// Expires every bound started so far; later ones wait for the next call.
    func expire() {
        let due = lock.withLock { () -> [@Sendable () -> Void] in
            defer { pending = [] }
            return pending
        }
        for expire in due { expire() }
    }
}

/// Counts calls made on any thread and lets a test wait for the nth one without a clock.
final class Arrivals: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var value: Int { lock.withLock { count } }

    @discardableResult
    func arrive() -> Int {
        let (count, ready) = lock.withLock { () -> (Int, [CheckedContinuation<Void, Never>]) in
            count += 1
            let ready = waiters.filter { $0.count <= count }.map(\.continuation)
            waiters.removeAll { $0.count <= count }
            return (count, ready)
        }
        for waiter in ready { waiter.resume() }
        return count
    }

    func wait(for target: Int) async {
        await withCheckedContinuation { continuation in
            let arrived = lock.withLock {
                if count >= target { return true }
                waiters.append((target, continuation))
                return false
            }
            if arrived { continuation.resume() }
        }
    }
}

/// Retries `step` until `done`, for the moment between a blocked read reporting its end and its worker freeing
/// itself, when a new read is still refused as busy. The bound matters only to a broken implementation.
@MainActor
func untilDone(_ done: () -> Bool, _ step: () async -> Void) async throws {
    for _ in 0..<3000 where !done() {
        await step()
        if !done() { try await Task.sleep(for: .milliseconds(10)) }
    }
}

private final class BlockedShelfRead: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let snapshot: ShelfSnapshot.Snapshot
    let calls = Arrivals()
    let finishes = Arrivals()
    private let lock = NSLock()
    private var offMain = true

    init(snapshot: ShelfSnapshot.Snapshot) { self.snapshot = snapshot }

    var readOffMain: Bool { lock.withLock { offMain } }
    var completed: Bool { finishes.value > 0 }

    func read(_ support: URL) -> ShelfSnapshot.Snapshot {
        lock.withLock { offMain = offMain && !Thread.isMainThread }
        if calls.arrive() > 1 { return ShelfSnapshot.read(support: support) }
        // A broken implementation that waits for this read on the main actor fails the test after a bound instead
        // of hanging the test process; the bound is far beyond any test's own pace.
        _ = release.wait(timeout: .now() + 30)
        finishes.arrive()
        return snapshot
    }
}

private final class BlockedShelfSummary: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let calls = Arrivals()
    private let lock = NSLock()
    private var offMain = true
    var ranOffMain: Bool { lock.withLock { offMain } }

    func summarize(_ row: ShelfRow, _ today: CalendarDate) -> ShelfCounts {
        lock.withLock { offMain = offMain && !Thread.isMainThread }
        calls.arrive()
        _ = release.wait(timeout: .now() + 30)
        return ShelfCounts.read(row, today)
    }
}

/// The waits here are on the reads themselves, and no read times out unless the test expires it, so a loaded
/// machine changes how long a test takes, never what it finds; the time limit catches a broken implementation.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ShelfModelTests {
    @Test func nowPagesArePreparedOffMainAndReusedByTheViews() async throws {
        let support = try temporaryFolder()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "garden-shed")
        try ShelfStore(supportDirectory: support).add(binder)
        let summary = BlockedShelfSummary()
        defer { summary.release.signal() }
        let model = ShelfModel(support: support, client: StandInRuntime().client, summarize: summary.summarize,
                               deadline: ManualDeadlines().deadline)
        model.refresh()
        await summary.calls.wait(for: 1)
        #expect(summary.ranOffMain && model.lastRefresh == nil)
        // MainActor can handle another refresh while the expensive summary is still running.
        model.refresh()
        summary.release.signal()
        await model.refreshAndWait()
        let row = try #require(model.rows.first)
        let counts = try #require(model.counts[row.folder])
        let expected = row.teka.nowPage(today: model.today)
        for bucket in Bucket.allCases { #expect(counts.count(bucket) == expected.count(bucket)) }
        // The Binder screen shows the same prepared page; rendering it buckets and sorts nothing again.
        let page = try #require(counts.page)
        #expect(Bucket.allCases.contains { page.count($0) > 0 })
        let note = BinderNote(client: StandInRuntime().client, support: support)
        for _ in 0..<20 {
            _ = ShelfRowView(row: row, counts: counts).body
            _ = NowView(row: row, today: model.today, page: page, reload: {}, note: note, editor: ItemEditor()).body
        }
        #expect(summary.calls.value == 1)
    }

    @Test func aBlockedRefreshLeavesTheMainActorResponsiveAndCoalescesReads() async throws {
        let support = try temporaryFolder()
        var snapshot = ShelfSnapshot.read(support: support)
        snapshot.note = "Invented completed refresh"
        let reader = BlockedShelfRead(snapshot: snapshot)
        defer { reader.release.signal() }
        let model = ShelfModel(support: support, client: StandInRuntime().client, readSnapshot: reader.read,
                               deadline: ManualDeadlines().deadline)
        model.refresh()
        await reader.calls.wait(for: 1)
        // The refresh returned and the main actor goes on while the read is still blocked.
        #expect(reader.readOffMain && !reader.completed)
        #expect(model.lastRefresh == nil && model.note == nil)
        // This task still executes on MainActor while the reader is waiting for its volume.
        for _ in 0..<20 { model.refresh() }
        await Task.yield()
        #expect(reader.calls.value == 1)
        reader.release.signal()
        await model.refreshAndWait()
        #expect(model.note == "Invented completed refresh" && model.lastRefresh != nil)
        #expect(reader.calls.value == 1)
    }

    @Test func aRemovalWaitsForASnapshotThatIncludesItsWrite() async throws {
        let support = try temporaryFolder()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "garden-shed")
        try ShelfStore(supportDirectory: support).add(binder)
        let snapshot = ShelfSnapshot.read(support: support)
        let row = try #require(snapshot.rows.first)
        let reader = BlockedShelfRead(snapshot: snapshot)
        defer { reader.release.signal() }
        let runtime = StandInRuntime()
        let removals = Arrivals()
        runtime.answers["shelf_remove"] = { request in
            try? ShelfStore(supportDirectory: support).remove(URL(fileURLWithPath: request["binder"]!.stringValue!))
            removals.arrive()
            return #"{"ok":true}"#
        }
        let model = ShelfModel(support: support, client: runtime.client, readSnapshot: reader.read,
                               deadline: ManualDeadlines().deadline)
        model.refresh()
        await reader.calls.wait(for: 1)
        try #require(reader.readOffMain)
        let removal = Task { await model.removeFromShelf(row) }
        await removals.wait(for: 1)
        try #require(runtime.sent.count == 1)
        reader.release.signal()
        await removal.value
        #expect(model.rows.isEmpty && model.note == nil)
        #expect(reader.calls.value == 2)
    }

    @Test func aStalledRefreshTimesOutAndDoesNotHoldACompletedRemoval() async throws {
        let support = try temporaryFolder()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "garden-shed")
        try ShelfStore(supportDirectory: support).add(binder)
        let snapshot = ShelfSnapshot.read(support: support)
        let row = try #require(snapshot.rows.first)
        let reader = BlockedShelfRead(snapshot: snapshot)
        defer { reader.release.signal() }
        let runtime = StandInRuntime()
        runtime.answers["shelf_remove"] = { request in
            try? ShelfStore(supportDirectory: support).remove(URL(fileURLWithPath: request["binder"]!.stringValue!))
            return #"{"ok":true}"#
        }
        // Only the stalled first read times out, when the test expires it; the real second read never does.
        let deadlines = ManualDeadlines()
        let model = ShelfModel(support: support, client: runtime.client, readSnapshot: reader.read,
                               deadline: deadlines.deadline)
        model.rows = snapshot.rows
        model.refresh()
        await reader.calls.wait(for: 1)
        deadlines.expire()
        await model.refreshAndWait()
        #expect(reader.calls.value == 1 && !reader.completed)
        #expect(model.note?.contains("could not refresh") == true)
        await model.removeFromShelf(row)
        // The removal is done while the stalled read still holds the worker.
        #expect(!reader.completed)
        #expect(runtime.sent.count == 1 && model.rows.isEmpty)
        for _ in 0..<20 { await model.refreshAndWait() }
        #expect(reader.calls.value == 1)
        reader.release.signal()
        await reader.finishes.wait(for: 1)
        #expect(model.rows.isEmpty) // the late pre-removal snapshot is discarded
        // The reader reports completion just before the disk worker frees itself, so a refresh in that gap is
        // still refused as busy; retry until the fresh read runs.
        try await untilDone({ reader.calls.value >= 2 }) { await model.refreshAndWait() }
        #expect(reader.calls.value == 2 && model.rows.isEmpty && model.note == nil)
    }

    @Test func creationErrorsSurviveTheCompletionOfAnOlderRefresh() async throws {
        let support = try temporaryFolder()
        let reader = BlockedShelfRead(snapshot: ShelfSnapshot.read(support: support))
        defer { reader.release.signal() }
        let model = ShelfModel(support: support, client: StandInRuntime().client, readSnapshot: reader.read,
                               deadline: ManualDeadlines().deadline)
        model.refresh()
        await reader.calls.wait(for: 1)
        await model.createBinder(parent: support, name: "invented", template: "generic", year: 2026)
        #expect(model.note?.hasPrefix("The binder was not created:") == true)
        reader.release.signal()
        await model.refreshAndWait()
        #expect(model.note?.hasPrefix("The binder was not created:") == true)
        #expect(reader.calls.value == 1)
    }

    @Test func addingAndRemovingAreCommandsTheRuntimeCarriesOut() async throws {
        let support = try temporaryFolder()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "kitchen-reno")
        let runtime = StandInRuntime()
        // The stand-in writes shelf.json as the runtime would, so the refresh shows the result.
        runtime.answers["shelf_add"] = { request in
            try? ShelfStore(supportDirectory: support).add(URL(fileURLWithPath: request["binder"]!.stringValue!, isDirectory: true))
            return #"{"ok":true}"#
        }
        runtime.answers["shelf_remove"] = { request in
            try? ShelfStore(supportDirectory: support).remove(URL(fileURLWithPath: request["binder"]!.stringValue!, isDirectory: true))
            return #"{"ok":true}"#
        }
        let model = ShelfModel(support: support, client: runtime.client)
        await model.add([binder])
        #expect(runtime.sent.map { $0["command"]?.stringValue } == ["shelf_add"])
        #expect(runtime.sent.first?["binder"]?.stringValue == binder.standardizedFileURL.path)
        #expect(model.rows.map(\.folder.standardizedFileURL) == [binder.standardizedFileURL] && model.note == nil)
        #expect(model.selection?.standardizedFileURL == binder.standardizedFileURL)
        await model.removeFromShelf(try #require(model.rows.first))
        #expect(model.rows.isEmpty && model.note == nil)
    }

    @Test func aFolderThatCannotBeAddedSaysSoAfterTheRefresh() async throws {
        let support = try temporaryFolder()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "kitchen-reno")
        let notABinder = try temporaryFolder()
        try Data("invented".utf8).write(to: notABinder.appendingPathComponent("note.txt"))
        let runtime = StandInRuntime()   // refuses every change
        let model = ShelfModel(support: support, client: runtime.client)
        await model.add([binder, notABinder])
        #expect(model.note?.contains("Could not add kitchen-reno: ") == true)
        #expect(model.note?.contains("Not added (no catalog.json; New Binder makes a binder): \(notABinder.lastPathComponent)") == true)
        // A folder that is not a binder is never sent.
        #expect(runtime.sent.count == 1)
        #expect(model.rows.isEmpty)
    }

    @Test func anEmptyFolderIsOfferedAsANewBinderInPlace() async throws {
        let support = try temporaryFolder()
        let empty = try temporaryFolder()
        let runtime = StandInRuntime()
        runtime.answers["create_binder"] = { _ in #"{"ok":true,"binder":null,"proposal":null}"# }
        let model = ShelfModel(support: support, client: runtime.client)
        var asked: [URL?] = []
        model.askForBinder = { folder, _ in asked.append(folder); return ("blank", "garden-shed") }
        await model.add([empty])
        #expect(asked == [empty])
        let sent = try #require(runtime.sent.first)
        #expect(runtime.sent.count == 1 && sent["command"]?.stringValue == "create_binder")
        #expect(sent["folder"]?.stringValue == empty.path && sent["name"]?.stringValue == "garden-shed")
        #expect(sent["parent"]?.stringValue == empty.deletingLastPathComponent().path)
        #expect(model.note == nil)
        // Declining leaves the folder alone and sends nothing.
        model.askForBinder = { _, _ in nil }
        await model.add([empty])
        #expect(runtime.sent.count == 1 && model.note == nil)
    }

    /// A name typed as a person would type it is sent as a valid binder name, never refused after the dialogs.
    @Test(arguments: [("MapleStreet", "maplestreet"), ("Maple Street", "maple-street"), ("  --Tax 2026!! ", "tax-2026"),
                      ("\u{65E5}\u{672C}", "new-binder")])
    func newBinderSendsTheTypedNameAsAValidOne(typed: String, sent: String) async throws {
        let runtime = StandInRuntime()
        runtime.answers["create_binder"] = { _ in #"{"ok":true,"binder":null,"proposal":null}"# }
        let model = ShelfModel(support: try temporaryFolder(), client: runtime.client)
        let parent = try temporaryFolder()
        model.askForBinder = { _, _ in ("blank", typed) }
        model.chooseParent = { parent }
        await model.startNewBinder()
        #expect(runtime.sent.first?["name"]?.stringValue == sent)
        #expect(model.note == nil)
    }

    /// For an empty folder, a name with nothing left falls back to the folder's own, then to the template's suggestion.
    @Test func anEmptyFolderFallsBackToItsOwnNameThenTheTemplates() async throws {
        let runtime = StandInRuntime()
        runtime.answers["create_binder"] = { _ in #"{"ok":true,"binder":null,"proposal":null}"# }
        let model = ShelfModel(support: try temporaryFolder(), client: runtime.client)
        let base = try temporaryFolder()
        let shed = base.appendingPathComponent("Garden Shed")
        let other = base.appendingPathComponent("\u{65E5}\u{672C}")
        for folder in [shed, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        model.askForBinder = { _, _ in ("tax-year", "!!") }
        await model.add([shed])
        await model.add([other])
        let year = Calendar.current.component(.year, from: Date())
        #expect(runtime.sent.map { $0["name"]?.stringValue } == ["garden-shed", "tax-\(year)"])
        #expect(model.note == nil)
    }

    @Test func aFolderThatCannotBeRemovedSaysSoAfterTheRefresh() async throws {
        let support = try temporaryFolder()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "garden-shed")
        try ShelfStore(supportDirectory: support).add(binder)
        let model = ShelfModel(support: support, client: StandInRuntime().client)
        await model.refreshAndWait()
        let row = try #require(model.rows.first)
        await model.removeFromShelf(row)
        #expect(model.note?.hasPrefix("Could not remove \(row.name): ") == true)
        #expect(model.rows.count == 1)
    }

    @Test func anUnreadableShelfIsSaidNotShownEmpty() async throws {
        let support = try temporaryFolder()
        try Data("{ not json".utf8).write(to: support.appendingPathComponent("shelf.json"))
        let model = ShelfModel(support: support, client: StandInRuntime().client)
        await model.refreshAndWait()
        #expect(model.rows.isEmpty && model.note != nil)
    }

    @Test func openingABinderPutsItOnTopAtTheNextRefresh() async throws {
        let support = try temporaryFolder()
        let a = try makeTeka(fixture: "sprava-v0", folderName: "kitchen-reno")
        let b = try makeTeka(fixture: "sprava-v0", folderName: "garden-shed")
        try ShelfStore(supportDirectory: support).add(a)
        try ShelfStore(supportDirectory: support).add(b)
        let model = ShelfModel(support: support, client: StandInRuntime().client)
        await model.refreshAndWait()
        let second = try #require(model.rows.last?.folder)
        model.selection = second
        await model.refreshAndWait()
        #expect(model.rows.first?.folder == second)
    }
}
