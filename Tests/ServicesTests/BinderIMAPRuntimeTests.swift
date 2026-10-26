import Capture
import Darwin
import Foundation
import Security
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
    /// What the setup checks were asked, in order.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var values: [String] = []
        func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    /// A development build: the Keychain refuses for want of an access group, so passwords live in memory only.
    static func memoryOnly() -> IMAPPasswords {
        IMAPPasswords(backend: .init(load: { _ in (errSecMissingEntitlement, nil) }, save: { _, _ in errSecMissingEntitlement }))
    }
    static let account = IMAPAccount(host: "mail.example.invalid", port: 993, security: .tls, user: "member@example.invalid")!
    static func support(_ name: String) throws -> URL {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-" + name + "-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(support); return support
    }
    static func request(_ command: String, _ folder: URL, _ fields: [(String, JSONValue)] = []) -> String {
        JSONWriter.compact(.obj([("command", .str(command)), ("binder", .str(folder.path))] + fields))
    }
    static func answer(_ runtime: BinderIMAPRuntime, _ command: String, _ folder: URL, _ fields: [(String, JSONValue)] = []) async throws -> JSONObject {
        try #require(JSONParser.parse(await runtime.respond(request(command, folder, fields))).value.objectValue)
    }
    static let accountFields: [(String, JSONValue)] = [("host", .str("mail.example.invalid")), ("port", .int(993)), ("security", .str("tls")), ("user", .str("member@example.invalid"))]

    @Test func disablingInFlightFetchPreventsPublicationBeforeAcknowledgment() async throws {
        let support = try Self.support("service"), folder = try makeTeka(fixture: "sprava-v0")
        let store = try BinderIMAPConnections(support: support, hash: { "fixture" }), passwords = Self.memoryOnly()
        let config = try store.configure(folder: folder, account: Self.account, mailbox: "INBOX")
        try passwords.store("invented", for: Self.account)
        let runHome = support.appendingPathComponent("capture/imap-runs/" + config.id.uuidString)
        try AtomicFile.makePrivateFolder(runHome)
        try AtomicFile.write(Data("{\"uid_validity\":7,\"last_seen_uid\":0}".utf8), to: runHome.appendingPathComponent("state.json"))
        let gate = FetchGate()
        let runtime = BinderIMAPRuntime(support: support, connections: store, passwords: passwords, fetch: { _, cwd, target in
            gate.enter()
            let until = Date().addingTimeInterval(3)
            while !gate.released, Date() < until { Thread.sleep(forTimeInterval: 0.005) }
            guard gate.released else { throw CancellationError() }
            try Data("From: member@example.invalid\r\nSubject: Invented\r\n\r\nInvented mail".utf8).write(to: target.appendingPathComponent("mail-1.eml"))
            try Data("{\"uid_validity\":7,\"last_seen_uid\":1}".utf8).write(to: cwd.appendingPathComponent("state.json"))
        })
        #expect(try await Self.answer(runtime, "imap_sync", folder)["ok"] == .bool(true))
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        let retirement = Task { try await runtime.retire(folder) }
        for _ in 0..<200 where (try store.configuration(for: folder))?.enabled == true { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try store.configuration(for: folder)?.enabled == false)
        gate.release(); try await retirement.value
        #expect(IntakeWatcher.candidates(in: folder).isEmpty)
    }

    @Test func anAuthenticationRefusalDisablesAutomaticChecksUntilExplicitReconnect() async throws {
        let support = try Self.support("auth"), folder = try makeTeka(fixture: "sprava-v0")
        let store = try BinderIMAPConnections(support: support, hash: { "fixture" }), passwords = Self.memoryOnly()
        _ = try store.configure(folder: folder, account: Self.account, mailbox: "INBOX")
        try passwords.store("invented", for: Self.account)
        let gate = FetchGate()
        let runtime = BinderIMAPRuntime(support: support, connections: store, passwords: passwords, fetch: { _, _, _ in
            gate.enter(); throw IMAPIntakeImport.Refused.authentication
        })
        _ = await runtime.respond(Self.request("imap_sync", folder))
        for _ in 0..<200 where (try store.configuration(for: folder))?.enabled == true { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        #expect(try store.configuration(for: folder)?.enabled == false)
        await runtime.tick(now: Date().addingTimeInterval(3600))
        #expect(try store.enabled().isEmpty)
    }

    @Test func unlistedBinderCannotStartAnImporterOrReachAServerAndUnknownCommandsAreRefused() async throws {
        let support = try Self.support("unlisted"), folder = try makeTeka(fixture: "sprava-v0")
        let store = try BinderIMAPConnections(support: support, hash: { "fixture" })
        let checks = BinderIMAPRuntime.Checks(probe: { _ in Issue.record("No server contact for an unlisted binder"); return .init(result: .ok) },
                                              folders: { _, _ in Issue.record("No sign-in for an unlisted binder"); return [] })
        let runtime = BinderIMAPRuntime(support: support, connections: store, passwords: Self.memoryOnly(), checks: checks,
                                        fetch: { _, _, _ in Issue.record("No server contact without explicit listed-binder consent") }, available: { _ in false })
        for command in ["imap_sync", "imap_configure", "imap_probe", "imap_folders", "run_script"] {
            let fields = Self.accountFields + [("mailbox", .str("INBOX")), ("password", .str("invented"))]
            #expect(try await Self.answer(runtime, command, folder, fields)["ok"] == .bool(false))
        }
    }

    @Test func checkingAServerTriesTheLikelyPortsInOrderAndStopsAtTheFirstThatAnswers() async throws {
        let support = try Self.support("probe"), folder = try makeTeka(fixture: "sprava-v0")
        let calls = Calls(), fingerprint = String(repeating: "ab", count: 32)
        let checks = BinderIMAPRuntime.Checks(probe: { account in
            calls.add("\(account.security.rawValue):\(account.port)")
            return account.port == 1993 ? .init(result: .untrusted, fingerprint: fingerprint) : .init(result: .unreachable)
        }, folders: { _, _ in [] })
        let runtime = BinderIMAPRuntime(support: support, connections: try BinderIMAPConnections(support: support, hash: { "fixture" }),
                                        passwords: Self.memoryOnly(), checks: checks, fetch: { _, _, _ in })
        let found = try await Self.answer(runtime, "imap_probe", folder, [("host", .str("127.0.0.1"))])
        #expect(calls.all == ["starttls:1143", "tls:1993"])
        #expect(found["result"] == .str("untrusted")); #expect(found["fingerprint"] == .str(fingerprint)); #expect(found["loopback"] == .bool(true))
        #expect(found["attempts"]?.arrayValue?.count == 2)
        // A security and port the person picked are tried alone.
        let picked = try await Self.answer(runtime, "imap_probe", folder, [("host", .str("mail.example.invalid")), ("security", .str("starttls")), ("port", .int(587))])
        #expect(calls.all.suffix(1) == ["starttls:587"]); #expect(picked["result"] == .str("unreachable"))
        #expect(try await Self.answer(runtime, "imap_probe", folder, [("host", .str("bad host"))])["ok"] == .bool(false))
    }

    @Test func signingInListsFoldersWithTheTypedPasswordAndExplainsARefusal() async throws {
        let support = try Self.support("folders"), folder = try makeTeka(fixture: "sprava-v0")
        let calls = Calls()
        let checks = BinderIMAPRuntime.Checks(probe: { _ in .init(result: .ok) }, folders: { account, password in
            calls.add(account.user + "/" + password)
            guard password == "invented-right" else { throw IMAPIntakeImport.Refused.authentication }
            return ["INBOX", "Labels/Workshop"]
        })
        let runtime = BinderIMAPRuntime(support: support, connections: try BinderIMAPConnections(support: support, hash: { "fixture" }),
                                        passwords: Self.memoryOnly(), checks: checks, fetch: { _, _, _ in })
        let refused = try await Self.answer(runtime, "imap_folders", folder, Self.accountFields + [("password", .str("invented-wrong"))])
        #expect(refused["ok"] == .bool(false)); #expect(refused["error"]?.stringValue?.contains("refused this username or password") == true)
        let listed = try await Self.answer(runtime, "imap_folders", folder, Self.accountFields + [("password", .str("invented-right"))])
        #expect(listed["folders"] == .array([.str("INBOX"), .str("Labels/Workshop")]))
        #expect(calls.all == ["member@example.invalid/invented-wrong", "member@example.invalid/invented-right"])
        // Without a typed password and none kept for the account, nothing reaches the server.
        #expect(try await Self.answer(runtime, "imap_folders", folder, Self.accountFields)["ok"] == .bool(false))
        #expect(calls.all.count == 2)
    }

    @Test func aRestartedDevelopmentRuntimeAsksForThePasswordAndNeverTriesTheServerWithoutIt() async throws {
        let support = try Self.support("restart"), folder = try makeTeka(fixture: "sprava-v0")
        let store = try BinderIMAPConnections(support: support, hash: { "fixture" })
        let gate = FetchGate()
        let fetch: IMAPIntakeImport.Fetch = { _, cwd, _ in
            gate.enter(); try Data("{\"uid_validity\":7,\"last_seen_uid\":4}".utf8).write(to: cwd.appendingPathComponent("state.json"))
        }
        let first = BinderIMAPRuntime(support: support, connections: store, passwords: Self.memoryOnly(), fetch: fetch)
        let connected = try await Self.answer(first, "imap_configure", folder, Self.accountFields + [("mailbox", .str("Labels/Workshop")), ("password", .str("invented"))])
        #expect(connected["enabled"] == .bool(true)); #expect(connected["needs_password"] == .bool(false))
        #expect(connected["user"] == .str("member@example.invalid")); #expect(connected["mailbox"] == .str("Labels/Workshop"))
        let state = try Data(contentsOf: support.appendingPathComponent("capture/imap.sqlite"))
        #expect(!String(decoding: state, as: UTF8.self).contains("invented\""))
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        while try await Self.answer(first, "imap_status", folder)["running"] == .bool(true) { try await Task.sleep(for: .milliseconds(5)) }

        let restartGate = FetchGate()
        let restarted = BinderIMAPRuntime(support: support, connections: store, passwords: Self.memoryOnly(), fetch: { config, cwd, target in
            restartGate.enter(); try fetch(config, cwd, target)
        })
        #expect(try await Self.answer(restarted, "imap_status", folder)["needs_password"] == .bool(true))
        await restarted.tick(now: Date().addingTimeInterval(3600))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!restartGate.entered)
        let resumed = try await Self.answer(restarted, "imap_password", folder, [("password", .str("invented"))])
        #expect(resumed["needs_password"] == .bool(false))
        for _ in 0..<200 where !restartGate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(restartGate.entered)
    }
}
