import Darwin
import Foundation
import Testing
import Companion

private let claimNodePath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    .map { String($0) + "/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
private final class LocalClaimSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if values[account] != nil { return false }
        values[account] = bytes; return true
    }
}

/// Concrete bounded transport + durable coordinator against an isolated server, with a lost successful reply.
@Test(.enabled(if: claimNodePath != nil)) func ownerClaimRecoveryWorksAcrossReopeningOverLocalHTTP() async throws {
    let script = #"""
    const http = require('node:http');
    const instance = '0123456789abcdef0123456789abcdef';
    let recorded, claimed = false, attempts = 0, invalid = false;
    const server = http.createServer((req, res) => {
      if (req.headers.authorization || req.headers.cookie || req.headers.referer) invalid = true;
      if (req.url === '/v0/health') {
        res.end(JSON.stringify({protocol:0, claimed:claimed && !invalid, instance})); return;
      }
      if (req.url !== '/v0/claim' || req.method !== 'POST') { res.writeHead(404); res.end(); return; }
      let body = ''; req.on('data', b => body += b); req.on('end', () => {
        const v = JSON.parse(body);
        if (!/^[0-9a-f]{64}$/.test(v.owner_token_sha256) || Buffer.from(v.setup_code, 'base64').length !== 32) invalid = true;
        if (recorded && recorded !== body) invalid = true;
        recorded = body; claimed = true; attempts++;
        if (attempts === 1) { req.socket.destroy(); return; }
        res.writeHead(invalid ? 409 : 204); res.end();
      });
    });
    server.listen(0, 'localhost', () => process.stdout.write(String(server.address().port) + '\n'));
    setTimeout(() => process.exit(0), 15000).unref();
    """#
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: try #require(claimNodePath))
    process.arguments = ["-e", script]; process.environment = [:]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
    let port = try #require(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-local-claim-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let database = folder.appendingPathComponent("state.sqlite"), secrets = LocalClaimSecrets()
    let identity = try CompanionRelayIdentity(origin: "http://localhost:\(port)", instance: "0123456789abcdef0123456789abcdef")
    _ = try CompanionOwnerVault(backend: secrets).prepare(identity, setupCode: Data(repeating: 27, count: 32).base64EncodedString())
    let first = try CompanionProfile(database: database, relay: identity, secrets: secrets)
    _ = try first.prepareAccount()
    let original = try CompanionOwnerConnection(profile: first)
    await #expect(throws: CompanionRelayError.invalid) { try await original.recoverClaim() }
    #expect(try first.ownerClaimState() == .pending)
    let reopened = try CompanionProfile(database: database, relay: identity, secrets: secrets)
    let restarted = try CompanionOwnerConnection(profile: reopened)
    #expect(try await restarted.recoverClaim() == .claimed)
    #expect(try await restarted.ownerTokenRefused() == .needsReset)
    #expect(try await restarted.recoverClaim() == .needsReset)
}
