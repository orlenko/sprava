import Capture
import Darwin
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct BinderIMAPRuntimeTests {
    final class FetchGate: @unchecked Sendable {
        private let lock = NSLock(); private var value = (entered: false, released: false)
        func enter() { lock.lock(); value.entered = true; lock.unlock() }
        func release() { lock.lock(); value.released = true; lock.unlock() }
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return value.entered }
        var released: Bool { lock.lock(); defer { lock.unlock() }; return value.released }
    }
    @Test func disablingInFlightFetchPreventsPublicationBeforeAcknowledgment() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-service-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(support)
        let folder = try makeTeka(fixture: "sprava-v0"), env = support.appendingPathComponent(".env")
        try AtomicFile.write(Data("IMAP_PASSWORD=invented\n".utf8), to: env)
        let store = try BinderIMAPConnections(support: support, hash: { "fixture" })
        let config = try store.configure(folder: folder, environment: env, mailbox: "INBOX")
        let runHome = support.appendingPathComponent("capture/imap-runs/" + config.id.uuidString)
        try AtomicFile.makePrivateFolder(runHome)
        try AtomicFile.write(Data("{\"uid_validity\":7,\"last_seen_uid\":0}".utf8), to: runHome.appendingPathComponent("state.json"))
        let gate = FetchGate()
        let runtime = BinderIMAPRuntime(support: support, connections: store, fetch: { _, cwd, target in
            gate.enter()
            let until = Date().addingTimeInterval(3)
            while !gate.released, Date() < until { Thread.sleep(forTimeInterval: 0.005) }
            guard gate.released else { throw CancellationError() }
            try Data("From: member@example.invalid\r\nSubject: Invented\r\n\r\nInvented mail".utf8).write(to: target.appendingPathComponent("mail-1.eml"))
            try Data("{\"uid_validity\":7,\"last_seen_uid\":1}".utf8).write(to: cwd.appendingPathComponent("state.json"))
        })
        let request = JSONWriter.compact(.obj([("command", .str("imap_sync")), ("binder", .str(folder.path))]))
        #expect(try JSONParser.parse(await runtime.respond(request)).value["ok"] == .bool(true))
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        let retirement = Task { try await runtime.retire(folder) }
        for _ in 0..<200 where (try store.configuration(for: folder))?.enabled == true { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try store.configuration(for: folder)?.enabled == false)
        gate.release(); try await retirement.value
        #expect(IntakeWatcher.candidates(in: folder).isEmpty)
    }
    @Test func anAuthenticationRefusalDisablesAutomaticChecksUntilExplicitReconnect() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-auth-fixture-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(support)
        let folder = try makeTeka(fixture: "sprava-v0"), env = support.appendingPathComponent(".env")
        try AtomicFile.write(Data("IMAP_PASSWORD=invented\n".utf8), to: env)
        let store = try BinderIMAPConnections(support: support, hash: { "fixture" })
        _ = try store.configure(folder: folder, environment: env, mailbox: "INBOX")
        let gate = FetchGate()
        let runtime = BinderIMAPRuntime(support: support, connections: store, fetch: { _, _, _ in
            gate.enter(); throw IMAPIntakeImport.Refused.authentication
        })
        let request = JSONWriter.compact(.obj([("command", .str("imap_sync")), ("binder", .str(folder.path))]))
        _ = await runtime.respond(request)
        for _ in 0..<200 where (try store.configuration(for: folder))?.enabled == true { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        #expect(try store.configuration(for: folder)?.enabled == false)
        await runtime.tick(now: Date().addingTimeInterval(3600))
        #expect(try store.enabled().isEmpty)
    }
    @Test func unlistedBinderCannotStartAnImporterAndUnknownCommandsAreRefused() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-unlisted-" + UUID().uuidString)
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = try BinderIMAPConnections(support: support, hash: { "fixture" })
        let runtime = BinderIMAPRuntime(support: support, connections: store, fetch: { _, _, _ in Issue.record("No server contact without explicit listed-binder consent") }, available: { _ in false })
        for command in ["imap_sync", "imap_configure", "run_script"] {
            let request = JSONWriter.compact(.obj([("command", .str(command)), ("binder", .str(folder.path)), ("mailbox", .str("INBOX")), ("environment", .str("/invented/.env"))]))
            #expect(try JSONParser.parse(await runtime.respond(request)).value["ok"] == .bool(false))
        }
    }
}
