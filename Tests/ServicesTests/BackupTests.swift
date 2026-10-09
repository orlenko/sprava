import Backup
import BinderFormat
import BinderStore
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// Runs the real restic against repositories in temporary folders. Skipped when restic is not installed.
@Suite(.serialized) struct BackupTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    static let hasRestic = Restic.locate() != nil
}

/// The whole path the app and the runtime take: commands, then the queued requests the backup job runs.
@Suite(.serialized) struct BackupCommandTests {
    // Real time: finished requests are kept for a day by the real clock.
    let now = Date()

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    @Test(.enabled(if: BackupTests.hasRestic && ProcessInfo.processInfo.environment["SPRAVA_BACKUP_KEY_FILE"] != nil))
    func setUpOffloadAndRestoreThroughCommands() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-backup-cmd-\(UUID().uuidString)")
        let support = base.appendingPathComponent("support")
        let c = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        #expect(try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])["ok"] == .bool(true))
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: now) }

        let key = try #require(try call(c, [("command", .str("backup_new_key"))])["key"]?.stringValue)
        let wrong = try call(c, [("command", .str("backup_setup")), ("key", .str("NOT-IT")), ("primary", .string(base.appendingPathComponent("icloud").path))])
        #expect(wrong["ok"] == .bool(false))
        let ok = try call(c, [("command", .str("backup_setup")), ("key", .string(key.lowercased())), ("primary", .string(base.appendingPathComponent("icloud").path))])
        #expect(ok["ok"] == .bool(true), "\(ok)")
        #expect(try call(c, [("command", .str("backup_second")), ("folder", .string(base.appendingPathComponent("disk").path))])["ok"] == .bool(true))

        let backup = Backup(support: support, removeFolder: { try FileManager.default.removeItem(at: $0) })
        let requests = BackupRequests(support: support)
        func drain() throws { while let r = try requests.next(), r.state == "queued" { try requests.run(r, backup: backup, deviceID: "dev", now: now) } }

        // Without the confirmation, the request stops and lists the open items.
        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("offload")), ("binder", .string(folder.path))])
        try drain()
        #expect(try requests.all().last?.state == "needs_confirmation")
        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("offload")), ("binder", .string(folder.path)), ("confirm_open_items", .bool(true))])
        try drain()
        #expect(try requests.all().last?.state == "done", "\((try? requests.all()) ?? [])")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let status = try call(c, [("command", .str("backup_status"))])
        let offloaded = try #require(status["offloaded"]?.arrayValue?.first)

        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("restore")), ("backup_id", offloaded["id"]!)])
        try drain()
        #expect(try requests.all().last?.state == "done", "\((try? requests.all()) ?? [])")
        #expect(Teka.read(folder).state == .ready)
    }
}
