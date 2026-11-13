import Companion
import Foundation
import SpravaKit
import Testing
@testable import Services

private func devFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sprava-dev-companion-" + UUID().uuidString + "-dev")
}

@Test func developmentCredentialsAreRefusedOutsideTheDevelopmentFolder() throws {
    let dev = devFolder(), other = devFolder()
    #expect(throws: DevelopmentCompanionCredentials.Refused.self) {
        _ = try DevelopmentCompanionCredentials(support: other, development: dev)
    }
    #expect(throws: DevelopmentCompanionCredentials.Refused.self) {
        _ = try CompanionRuntimeRequests.development(support: other, watch: nil, developmentSupport: dev)
    }
    #expect(throws: DevelopmentCompanionCredentials.Refused.self) {
        _ = try DevelopmentCompanionCredentials(support: SpravaPaths.supportDirectory(), development: dev)
    }
    #expect(!FileManager.default.fileExists(atPath: dev.path) && !FileManager.default.fileExists(atPath: other.path))
}

@Test func developmentCredentialsInsertOnceReadBackAndRemove() throws {
    let dev = devFolder(); defer { try? FileManager.default.removeItem(at: dev) }
    let store = try DevelopmentCompanionCredentials(support: dev, development: dev)
    let account = "https://relay.example:invented-account"
    #expect(try store.read(account: account) == nil)
    #expect(try store.insert(account: account, bytes: Data([1, 2, 3])))
    #expect(try !store.insert(account: account, bytes: Data([9])))
    #expect(try store.read(account: account) == Data([1, 2, 3]))
    let folder = dev.appendingPathComponent("companion/dev-credentials")
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(names.count == 1 && !names[0].contains("relay"))
    let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(names[0]).path)[.posixPermissions] as? Int
    let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
    #expect(mode == 0o600 && folderMode == 0o700)
    try store.remove(account: account)
    try store.remove(account: account)
    #expect(try store.read(account: account) == nil)
}

@Test func theDevelopmentPhoneActionsKeepTheirStateInTheDevelopmentFolder() async throws {
    let dev = devFolder(); defer { try? FileManager.default.removeItem(at: dev) }
    let helper = try CompanionRuntimeRequests.development(support: dev, watch: nil, developmentSupport: dev)
    #expect(helper.requests.handles("companion_pairing_start") && !helper.requests.handles("companion_reset"))
    #expect(!FileManager.default.fileExists(atPath: dev.path))
    // Unconfigured: devices are listed from the development state without touching any credential.
    let answer = await withCheckedContinuation { continuation in
        _ = helper.requests.submit(#"{"command":"companion_devices"}"#) { reply, _, _ in continuation.resume(returning: reply) }
    }
    #expect(try JSONParser.parse(answer).value == .obj([("ok", .bool(true)), ("devices", .array([]))]))
}
