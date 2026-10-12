@testable import Backup
import BinderFormat
import BinderStore
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// The backup request queue (`backup/backup.sqlite`): what the app asks for and the runtime's backup job runs one at
/// a time. restic runs against repositories in temporary folders only; those tests are skipped without it. Invented
/// binders only.
@Suite(.serialized) struct BackupRequestsTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    static let hasRestic = Restic.locate() != nil

    func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-requests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func request(_ kind: String, binder: String? = "/Invented/estate-example", state: String = "queued", at: Date? = nil) -> BackupRequests.Request {
        BackupRequests.Request(id: UUIDv7.make(now: now), kind: kind, binder: binder, state: state, at: ISOTime.string(at ?? now))
    }

    @Test func aRequestAlreadyWaitingIsNotQueuedTwice() throws {
        let queue = BackupRequests(support: try temp("twice"))
        let first = try queue.enqueue(request("backup_now"), now: now)
        let again = try queue.enqueue(request("backup_now"), now: now)
        #expect(again.id == first.id)
        try queue.enqueue(request("backup_now", binder: "/Invented/garden-shed"), now: now)
        try queue.enqueue(request("drill"), now: now)
        #expect(try queue.all().count == 3)
        #expect(throws: Backup.Failure.self) { try queue.enqueue(request("restore"), now: now) }
    }

    @Test func independentQueueWritersKeepEveryRequest() async throws {
        let support = try temp("writers")
        let now = self.now
        let submitted = (0..<24).map { request("backup_now", binder: "/Invented/binder-\($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for request in submitted {
                group.addTask { try BackupRequests(support: support).enqueue(request, now: now) }
            }
            try await group.waitForAll()
        }
        let stored = try BackupRequests(support: support).all()
        #expect(Set(stored.map(\.id)) == Set(submitted.map(\.id)))
        #expect(stored.count == submitted.count)
    }

    @Test func aQueueThatCannotBeReadIsLeftAsItIs() throws {
        let support = try temp("unreadable")
        let queue = BackupRequests(support: support)
        let url = BackupRequests.databaseURL(support)
        try AtomicFile.makePrivateFolder(url.deletingLastPathComponent())
        let garbage = Data("[{\"id\": ".utf8)
        try garbage.write(to: url)
        #expect(throws: Backup.Failure.self) { try queue.all() }
        #expect(throws: Backup.Failure.self) { try queue.enqueue(request("backup_now"), now: now) }
        #expect(throws: Backup.Failure.self) { try queue.recoverInterrupted(now: now) }
        #expect(try Data(contentsOf: url) == garbage)
        // A link in its place is refused, not followed, and never saved over.
        try FileManager.default.removeItem(at: url)
        let elsewhere = support.appendingPathComponent("elsewhere.json")
        try Data("[]".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
        #expect(throws: Backup.Failure.self) { try queue.all() }
        #expect(throws: Backup.Failure.self) { try queue.enqueue(request("backup_now"), now: now) }
        #expect(try Data(contentsOf: elsewhere) == Data("[]".utf8))
    }

    @Test func aRequestCutOffByAStopIsFailedNotRunAgain() throws {
        let queue = BackupRequests(support: try temp("cut-off"))
        let running = try queue.enqueue(request("backup_now"), now: now)
        try queue.update(running.id, now: now) { $0.state = "running" }
        try queue.recoverInterrupted(now: now)
        let after = try #require(try queue.all().first)
        #expect(after.state == "failed" && after.message?.contains("interrupted") == true)
        #expect(try queue.next() == nil)
    }

    @Test func queuedRequestsComeFirstThenTheWaitingOffloadRetriedLongestAgo() throws {
        let queue = BackupRequests(support: try temp("next"))
        let older = try queue.enqueue(request("offload", binder: "/Invented/a", state: "waiting_for_icloud", at: now.addingTimeInterval(-600)), now: now)
        try queue.enqueue(request("offload", binder: "/Invented/b", state: "waiting_for_icloud", at: now.addingTimeInterval(-60)), now: now)
        #expect(try queue.next()?.id == older.id)
        let queued = try queue.enqueue(request("drill"), now: now)
        #expect(try queue.next()?.id == queued.id)
    }

    @Test func finishedRequestsAreKeptForADay() throws {
        let queue = BackupRequests(support: try temp("kept"))
        try queue.enqueue(request("backup_now", binder: "/Invented/a", state: "done", at: now.addingTimeInterval(-90_000)), now: now)
        try queue.enqueue(request("backup_now", binder: "/Invented/b", state: "failed", at: now.addingTimeInterval(-3600)), now: now)
        #expect(try queue.all().map(\.binder) == ["/Invented/b"])
    }

    @Test func aRequestNoLongerQueuedIsNeverRun() throws {
        let support = try temp("gone")
        let queue = BackupRequests(support: support)
        let backup = Backup(support: support, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: nil, uploadCheck: { _ in .uploaded },
                            secondLocationCheck: { _ in true })
        #expect(throws: Backup.Failure.self) {
            try queue.run(request("backup_now"), backup: backup, deviceID: "dev", nameCollides: { _ in false }, now: now)
        }
        #expect(try queue.all().isEmpty)
    }

    @Test func aFailureIsRecordedWithItsReason() throws {
        let support = try temp("failed")
        let queue = BackupRequests(support: support)
        // Not set up: the offload fails and says why; the queue records it, with the time it ended.
        let backup = Backup(support: support, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: nil, uploadCheck: { _ in .uploaded },
                            secondLocationCheck: { _ in true })
        let r = try queue.enqueue(request("offload"), now: now)
        let ended = now.addingTimeInterval(120)
        try queue.run(r, backup: backup, deviceID: "dev", nameCollides: { _ in false }, now: now, finishedAt: { ended })
        let after = try #require(try queue.all().first)
        #expect(after.state == "failed" && after.message == "set up backup first" && after.at == ISOTime.string(ended))
    }

    @Test(.enabled(if: hasRestic)) func backUpNowAndADrillRunAndAreRecordedDone() throws {
        let base = try temp("run")
        let support = base.appendingPathComponent("support")
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        let backup = Backup(support: support, key: "TEST-KEY-AAAAA-BBBBB", uploadCheck: { _ in .uploaded }, secondLocationCheck: { _ in true })
        try backup.setUp(primary: base.appendingPathComponent("icloud/Sprava Backup"), iCloudKeychain: false)
        let queue = BackupRequests(support: support)
        for kind in ["backup_now", "drill"] {
            let r = try queue.enqueue(request(kind, binder: folder.path), now: now)
            try queue.run(r, backup: backup, deviceID: "dev", nameCollides: { _ in false }, now: now)
            let after = try #require(try queue.all().first { $0.id == r.id })
            #expect(after.state == "done", "\(kind): \(after.message ?? "")")
        }
        #expect(backup.status(checkUpload: false).binders.count == 1)
    }
}
