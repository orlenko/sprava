import Foundation
import Testing
@testable import Companion

private func linkStart(id: String? = nil, secret: String? = nil, device: String? = nil, key: Data? = nil) -> CompanionPairingStart {
    CompanionPairingStart(deviceID: device ?? CompanionWire.base64(Data(repeating: 1, count: 16)),
        ownerPublicKey: key ?? Data(repeating: 2, count: 32),
        created: CompanionCreatedPairing(id: id ?? CompanionWire.base64(Data(repeating: 3, count: 16)),
            secret: secret ?? CompanionWire.base64(Data(repeating: 4, count: 16)), expiresAt: "2031-01-02T10:00:00Z"),
        deadline: "2031-01-02T09:55:00Z")
}
private final class LinkMetadataSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    private var forbidden = false
    func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !forbidden else { throw CompanionCredentialError.unavailable }; return entries[account]
    }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !forbidden else { throw CompanionCredentialError.unavailable }
        guard entries[account] == nil else { return false }; entries[account] = bytes; return true
    }
    func forbid() { lock.lock(); forbidden = true; lock.unlock() }
}

@Test func thePairingLinkKeepsTheExactWireFieldsInTheFragmentAndSendsNoSecretInTheURLPathOrQuery() throws {
    let relay = try CompanionRelayIdentity(origin: "https://relay.example:8443", instance: String(repeating: "a", count: 32))
    let start = linkStart()
    let link = try CompanionPairingLink.make(webOrigin: "https://phone.example", relay: relay, start: start)
    let url = try #require(URLComponents(string: link))
    #expect(url.scheme == "https" && url.host == "phone.example" && url.path == "/")
    #expect(url.query == nil && url.user == nil && url.password == nil)
    let fragment = try #require(url.fragment)
    #expect(fragment.hasPrefix("pair=v0."))
    let fields = String(fragment.dropFirst("pair=v0.".count)).split(separator: ".").map(String.init)
    #expect(fields.count == 5)
    #expect(try CompanionWire.decode(fields[0]) == Data(relay.origin.utf8))
    #expect(fields[1] == start.created.id && fields[2] == start.created.secret && fields[4] == start.deviceID)
    #expect(try CompanionWire.decode(fields[3]) == start.ownerPublicKey)
    #expect(!String(link.split(separator: "#")[0]).contains(start.created.secret))
    #expect(try CompanionPairingLink.make(webOrigin: "http://localhost:4400", relay: relay, start: start)
        .hasPrefix("http://localhost:4400/#pair=v0."))
}

@Test func aPairingLinkRejectsNonOriginsAndMalformedSecretsIDsOrPublicKeys() throws {
    let relay = try CompanionRelayIdentity(origin: "https://relay.example", instance: String(repeating: "a", count: 32))
    for origin in ["http://phone.example", "https://phone.example/path", "https://person@phone.example",
                   "https://phone.example?key=example", "https://phone.example#extra", "https://PHONE.example"] {
        #expect(throws: CompanionOwnerPairingError.invalid) {
            try CompanionPairingLink.make(webOrigin: origin, relay: relay, start: linkStart())
        }
    }
    for start in [linkStart(id: "invalid"), linkStart(secret: "invalid"), linkStart(device: "invalid"),
                  linkStart(key: Data(repeating: 1, count: 31))] {
        #expect(throws: CompanionOwnerPairingError.invalid) {
            try CompanionPairingLink.make(webOrigin: "https://phone.example", relay: relay, start: start)
        }
    }
}

@Test func ownerConfigurationIsCommittedMetadataAndDoesNotReadCredentials() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-link-metadata-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let database = folder.appendingPathComponent("state.sqlite")
    let secrets = LinkMetadataSecrets()
    let profile = try CompanionProfile(database: database,
        relay: CompanionRelayIdentity(origin: "https://relay.example", instance: String(repeating: "a", count: 32)), secrets: secrets)
    #expect(try profile.ownerConfiguration() == nil)
    _ = try profile.prepareAccount(beforeCommit: {}, webOrigin: "https://phone.example")
    secrets.forbid()
    let reopened = try #require(try CompanionProfile.openConfigured(database: database, secrets: secrets))
    let configuration = try #require(try reopened.ownerConfiguration())
    #expect(configuration.origin == "https://relay.example" && configuration.instance == String(repeating: "a", count: 32))
    #expect(configuration.webOrigin == "https://phone.example")
}
