@testable import BinderStore
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// The owner record and the op log are read without following a link, without waiting on a FIFO, and never
/// whole when they are larger than their limits (issue #285). Each read runs off the test's thread, so a read that
/// waits fails the test instead of hanging it. Invented binders only.
@Suite struct SafeReadsTests {
    func adopted() throws -> URL {
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: Date())
        return folder
    }

    /// Runs `body` on another thread and returns its result, or records an issue after ten seconds.
    func returns<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        let box = ResultBox<T>(), done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { box.value = body(); done.signal() }
        guard done.wait(timeout: .now() + 10) == .success else { Issue.record("the read waited"); return nil }
        return box.value
    }

    @Test func theOwnerRecordIsReadOnlyFromABoundedRegularFile() throws {
        let folder = try adopted()
        let owner = folder.appendingPathComponent(".sprava/owner.json")
        #expect(Owner.device(of: folder) == "dev")
        try FileManager.default.removeItem(at: owner)
        #expect(mkfifo(owner.path, 0o600) == 0)
        #expect(returns { Owner.device(of: folder) } == .some(nil))
        try FileManager.default.removeItem(at: owner)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-owner-\(UUID().uuidString).json")
        try Data(#"{"device":"dev"}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: owner, withDestinationURL: outside)
        #expect(Owner.device(of: folder) == nil)
        try FileManager.default.removeItem(at: owner)
        try Data((#"{"device":"dev","padding":""# + String(repeating: "x", count: 70_000) + #""}"#).utf8).write(to: owner)
        #expect(Owner.device(of: folder) == nil)
    }

    @Test func theOpLogIsNeverWaitedOnFollowedOrLoadedWhenTooLarge() throws {
        let folder = try adopted()
        let log = folder.appendingPathComponent(".sprava/ops.ndjson")
        #expect(try TekaStore(folder: folder).readOpLog().ops.isEmpty == false)
        // A sparse file of a gigabyte is refused, not read.
        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        #expect(returns { (try? TekaStore(folder: folder).readOpLog()) == nil } == true)
        // A FIFO is refused without waiting, and so is a link.
        try FileManager.default.removeItem(at: log)
        #expect(mkfifo(log.path, 0o600) == 0)
        #expect(returns { (try? TekaStore(folder: folder).readOpLog()) == nil } == true)
        try FileManager.default.removeItem(at: log)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-ops-\(UUID().uuidString).ndjson")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try TekaStore(folder: folder).readOpLog() }
        // Only a missing log reads as empty.
        try FileManager.default.removeItem(at: log)
        #expect(try TekaStore(folder: folder).readOpLog().ops.isEmpty)
        try FileManager.default.removeItem(at: folder)
    }
}

private final class ResultBox<T>: @unchecked Sendable { var value: T? }
