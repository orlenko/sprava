import Darwin
import Foundation
import Testing
@testable import Companion

private let pairingNodePath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    .map { String($0) + "/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
private final class HTTPPairingSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
    func remove(account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}
private final class HTTPPairingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> String { lock.lock(); defer { lock.unlock() }; return date.ISO8601Format() }
    func advance() { lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(3) }
}

/// Independent Node phone crypto and a disposable relay; real URLSession, invented state, no live Keychain.
@Test(.enabled(if: pairingNodePath != nil)) func ownerPairsAnIndependentPhoneOverHTTPAndRecoversALostKeysUpload() async throws {
    let script = #"""
    const http = require('node:http'), c = require('node:crypto');
    const instance = '0123456789abcdef0123456789abcdef', P = Buffer.alloc(16,31).toString('base64url');
    const secret = Buffer.alloc(16,32).toString('base64url'), phone = c.generateKeyPairSync('x25519');
    const B = phone.publicKey.export({format:'jwk'}).x;
    let hash, D, A, W, Kd, hello, signed, signedName, acknowledged = false, keyAttempts = 0, creates = 0;
    const decode = s => Buffer.from(s, 'base64url');
    function derive(z, kind, length) {
      return Buffer.from(c.hkdfSync('sha256', z, Buffer.from(P), Buffer.concat([
        Buffer.from('sprava-companion/v0 ' + kind), decode(A), decode(B), decode(D)]), length));
    }
    function seal(name, key, payload) {
      const n = c.randomBytes(12), cipher = c.createCipheriv('aes-256-gcm', key, n);
      cipher.setAAD(Buffer.from('sprava-companion/v0|' + name + '|wrap|0'));
      const bytes = Buffer.concat([cipher.update(JSON.stringify(payload)), cipher.final(), cipher.getAuthTag()]);
      return Buffer.from(JSON.stringify({v:0, kid:'wrap', e:0, n:n.toString('base64url'), c:bytes.toString('base64url')}));
    }
    function open(name, kid, key, bytes) {
      const v = JSON.parse(bytes); if (v.v !== 0 || v.kid !== kid || v.e !== 1) throw Error('binding');
      const ciphertext = decode(v.c), decipher = c.createDecipheriv('aes-256-gcm', key, decode(v.n));
      decipher.setAAD(Buffer.from('sprava-companion/v0|' + name + '|' + kid + '|1'));
      decipher.setAuthTag(ciphertext.subarray(-16));
      return JSON.parse(Buffer.concat([decipher.update(ciphertext.subarray(0,-16)), decipher.final()]));
    }
    const server = http.createServer((req,res) => {
      const chunks = []; req.on('data', b => chunks.push(b)); req.on('end', () => {
        try {
          if (req.headers.cookie || req.headers.referer) throw Error('headers');
          const body = Buffer.concat(chunks);
          if (req.url === '/v0/health') { res.end(JSON.stringify({protocol:0,claimed:!!hash,instance})); return; }
          if (req.url === '/v0/claim') {
            const v = JSON.parse(body);
            if (v.setup_code !== Buffer.alloc(32,33).toString('base64') || req.headers.authorization) throw Error('claim');
            hash = v.owner_token_sha256; res.writeHead(204); res.end(); return;
          }
          const auth = req.headers.authorization || '';
          if (!auth.startsWith('Bearer ') || c.createHash('sha256').update(auth.slice(7)).digest('hex') !== hash) {
            res.writeHead(401); res.end(); return;
          }
          if (req.url === '/v0/pairings' && req.method === 'POST') {
            if (++creates !== 1) throw Error('create repeated');
            const v = JSON.parse(body); D = v.device_id; A = v.owner_public_key;
            const owner = c.createPublicKey({key:{kty:'OKP',crv:'X25519',x:A},format:'jwk'});
            const z = c.diffieHellman({privateKey:phone.privateKey,publicKey:owner});
            W = derive(z,'wrap',32); Kd = derive(z,'device',32);
            process.stdout.write(String(derive(z,'confirm',4).readUInt32BE() % 1000000).padStart(6,'0') + '\n');
            const payload = {label:'Pocket',pad:''}; payload.pad = ' '.repeat(512 - Buffer.byteLength(JSON.stringify(payload)));
            hello = seal('pairings/' + P + '/hello',W,payload);
            res.end(JSON.stringify({pairing_id:P,secret,expires_at:new Date(Date.now()+600000).toISOString().replace(/\.\d{3}Z$/,'Z')})); return;
          }
          if (req.url === '/v0/objects/devices/' + D + '/keys/1' && req.method === 'PUT') {
            if (signed && !signed.equals(body)) throw Error('retry bytes changed');
            signed = body; signedName = 'devices/' + D + '/keys/1';
            if (++keyAttempts === 1) { req.socket.destroy(); return; }
            res.writeHead(204); res.end(); return;
          }
          if (req.url === '/v0/pairings/' + P + '/key' && req.method === 'PUT') {
            if (!signed || keyAttempts < 2) throw Error('wrap before durable signed keys');
            const wrap = open('pairings/' + P + '/key','wrap',W,body), envelope = JSON.parse(signed);
            const S = c.createPublicKey({key:{kty:'OKP',crv:'Ed25519',x:wrap.owner_signing_key},format:'jwk'});
            const signatureInput = Buffer.concat([Buffer.from('sprava-companion/v0 signed|' + signedName + '|device|1|'),
              decode(envelope.n),decode(envelope.c)]);
            if (!c.verify(null,signatureInput,S,decode(envelope.s))) throw Error('signature');
            const keys = open(signedName,'device',Kd,signed);
            if (keys.account_key !== wrap.account_key || keys.device_id !== D || wrap.device_id !== D || wrap.min_index_revision !== 0) throw Error('payload');
            acknowledged = true; res.writeHead(204); res.end(); return;
          }
          if (req.url === '/v0/pairings/' + P) {
            res.end(JSON.stringify(acknowledged ? {state:'acknowledged',device_id:'untrusted-unused',device_public_key:'bad',hello:'bad'} :
              {state:'joined',device_id:D,device_public_key:B,hello:hello.toString('base64url')})); return;
          }
          res.writeHead(404); res.end();
        } catch { res.writeHead(502); res.end(); }
      });
    });
    server.listen(0,'localhost',() => process.stdout.write(String(server.address().port) + '\n'));
    setTimeout(() => process.exit(0),20000).unref();
    """#
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: try #require(pairingNodePath))
    process.arguments = ["-e", script]; process.environment = [:]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
    func line() -> String { String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    let port = try #require(Int(line()))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-native-pairing-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let secrets = HTTPPairingSecrets(), database = folder.appendingPathComponent("state.sqlite")
    let identity = try CompanionRelayIdentity(origin: "http://localhost:\(port)", instance: "0123456789abcdef0123456789abcdef")
    let owner = try CompanionOwnerVault(backend: secrets).prepare(identity, setupCode: Data(repeating: 33, count: 32).base64EncodedString())
    let profile = try CompanionProfile(database: database, relay: identity, secrets: secrets)
    _ = try profile.prepareAccount()
    let connection = try CompanionOwnerConnection(profile: profile)
    #expect(try await connection.recoverClaim() == .claimed)
    let flow = try CompanionOwnerPairingFlow(profile: profile), start = try await flow.start()
    guard case .confirmation(let approval) = try await flow.poll(deviceID: start.deviceID) else { Issue.record("Expected confirmation"); return }
    try #require(approval.confirmation == line())
    #expect(try profile.pairingDelivery(deviceID: start.deviceID) == nil)
    let delivery = try await flow.confirm(approval) // The simulated person has now compared both codes.
    let clock = HTTPPairingClock(), client = try CompanionOwnerRelay(relay: identity, token: owner.ownerToken)
    let first = CompanionOwnerPairingDelivery(profile: profile, connection: connection, transport: client, now: { clock.now() })
    await #expect(throws: CompanionRelayError.invalid) { try await first.step(deviceID: start.deviceID) }
    clock.advance()
    let reopened = try CompanionProfile(database: database, relay: identity, secrets: secrets)
    let restarted = CompanionOwnerPairingDelivery(profile: reopened, connection: try CompanionOwnerConnection(profile: reopened),
        transport: client, now: { clock.now() })
    guard case .acknowledged = try await restarted.step(deviceID: start.deviceID) else { Issue.record("Phone did not validate and acknowledge keys"); return }
    #expect(try reopened.pairingDelivery(deviceID: start.deviceID)?.deviceKeys == delivery.deviceKeys)
    #expect(try reopened.deviceRecords().first?.state == .active && reopened.deviceRecords().first?.keyReady == false)
}
