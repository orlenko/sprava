import CryptoKit
import Darwin
import Foundation
import Testing
import Companion

private let nodePath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    .map { String($0) + "/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
private func fixtureCall<T>(_ step: String, _ body: () async throws -> T) async throws -> T {
    do { return try await body() }
    catch { Issue.record("Local HTTP fixture failed at \(step)"); throw error }
}

/// Real URLSession against an invented, disposable localhost server; never the author's relay or profile.
@Test(.enabled(if: nodePath != nil)) func ownerTransportWorksOverHTTPAndNeverFollowsRedirectsOrSendsCookies() async throws {
    let script = #"""
    const http = require('node:http'), crypto = require('node:crypto');
    const token = Buffer.alloc(32, 13).toString('base64url'), id = Buffer.alloc(16, 8).toString('base64url');
    const instance = 'fedcba9876543210fedcba9876543210';
    let sink = 0, badHeaders = 0;
    const server = http.createServer((req, res) => {
      if (req.headers.cookie || req.headers.referer) badHeaders++;
      if (req.url === '/sink') { sink++; res.end(); return; }
      if (req.url === '/v0/health') {
        res.setHeader('Set-Cookie', 'fixture=private; Path=/');
        res.end(JSON.stringify({protocol:0, claimed:sink === 0 && badHeaders === 0, instance})); return;
      }
      if (req.url === '/v0/claim') {
        if (req.headers.authorization) badHeaders++;
        let body = ''; req.on('data', b => body += b); req.on('end', () => {
          const v = JSON.parse(body);
          const expected = crypto.createHash('sha256').update(token).digest('hex');
          res.statusCode = v.owner_token_sha256 === expected ? 204 : 400; res.end();
        }); return;
      }
      if (req.headers.authorization !== 'Bearer ' + token) { res.statusCode = 401; res.end(); return; }
      if (req.method === 'DELETE') {
        res.writeHead(302, {Location:'/sink'}); res.end(); return;
      }
      if (req.url === '/v0/pairings' && req.method === 'POST') {
        let body = ''; req.on('data', b => body += b); req.on('end', () => {
          const v = JSON.parse(body);
          if (v.device_id !== id || v.owner_public_key !== Buffer.alloc(32,10).toString('base64url')) {
            res.statusCode = 400; res.end(); return;
          }
          res.end(JSON.stringify({pairing_id:id, secret:id, expires_at:'2026-10-15T12:00:00Z'}));
        }); return;
      }
      if (req.method === 'PUT') {
        let body = ''; req.on('data', b => body += b); req.on('end', () => {
          res.statusCode = body === 'sealed-fixture' && req.headers['content-type'] === 'application/octet-stream' ? 204 : 400;
          res.end();
        }); return;
      }
      res.writeHead(200); res.write(Buffer.alloc(8192, 32)); res.end(Buffer.alloc(1, 32));
    });
    server.listen(0, 'localhost', () => process.stdout.write(String(server.address().port) + '\n'));
    setTimeout(() => process.exit(0), 15000).unref();
    """#
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: try #require(nodePath))
    process.arguments = ["-e", script]
    process.environment = [:]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    // Stop only this owned disposable fixture, even when a request failed.
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
    // read(upToCount:) can wait for 32 bytes or EOF; the child keeps its pipe open while serving.
    let bytes = output.fileHandleForReading.availableData
    let port = try #require(Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    let identity = try CompanionRelayIdentity(origin: "http://localhost:\(port)", instance: "fedcba9876543210fedcba9876543210")
    let token = CompanionWire.base64(Data(repeating: 13, count: 32)), id = CompanionWire.base64(Data(repeating: 8, count: 16))
    let client = try CompanionOwnerRelay(relay: identity, token: token)
    #expect(try await fixtureCall("initial health") { try await client.health() }.value?.claimed == true)
    let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    let setup = Data(repeating: 15, count: 32).base64EncodedString()
    let claim = Data("{\"setup_code\":\"\(setup)\",\"owner_token_sha256\":\"\(hash)\"}".utf8)
    #expect(try await fixtureCall("claim") { try await client.claim(claim) } == 204)
    #expect(try await fixtureCall("create pairing") { try await client.createPairing(deviceID: id, publicKey: Data(repeating: 10, count: 32)) }.value?.id == id)
    #expect(try await fixtureCall("deliver key") { try await client.deliverKey(pairingID: id, bytes: Data("sealed-fixture".utf8)) } == 204)
    await #expect(throws: CompanionRelayError.invalid) { try await client.deletePairing(id) }
    await #expect(throws: CompanionRelayError.invalid) { try await client.pairing(id) }
    #expect(try await fixtureCall("final health") { try await client.health() }.value?.claimed == true)
}
