import Foundation
import Security
@testable import Services
import SpravaKit
import Testing

@Suite struct ClaudeCredentialStorageTests {
    final class Keychain: @unchecked Sendable {
        let lock = NSLock()
        var token: String?
        func storage() -> ClaudeCredentialStorage {
            .init(load: { self.lock.withLock { self.token.map { (errSecSuccess, Data($0.utf8)) } ?? (errSecItemNotFound, nil) } },
                  save: { token in self.lock.withLock { self.token = token }; return errSecSuccess })
        }
    }
    @Test func theSubscriptionTokenSurvivesAStorageRestartAndDisconnectRemovesIt() throws {
        let keychain = Keychain(), first = keychain.storage()
        #expect(try first.read() == nil)
        try first.replace("invented-token")
        #expect(try first.read() == "invented-token"); #expect(first.persistent)
        #expect(try keychain.storage().read() == "invented-token")
        try first.replace(nil); #expect(try keychain.storage().read() == nil)
    }
    @Test func lockedOrDamagedKeychainsCannotSilentlyDowngradeCredentialStorage() throws {
        for refusal in [errSecInteractionNotAllowed, errSecDecode, errSecMissingEntitlement] {
            let storage = ClaudeCredentialStorage(load: { (refusal, nil) }, save: { _ in refusal })
            #expect(throws: (any Error).self) { try storage.replace("invented-token") }
            #expect(throws: (any Error).self) { try storage.read() }
        }
    }
    @Test func statusAfterAnEphemeralCredentialIsLostDoesNotAdvertiseAnEnabledAccount() async throws {
        let f = try ClaudeConversationTests.Fixture(); try await f.connect()
        #expect(try await f.request("claude_status")["enabled"] == .bool(true))
        f.engine.lock.withLock { f.engine.token = nil }
        #expect(try await f.request("claude_status")["enabled"] == .bool(false))
        #expect(try await f.request("claude_binder")["enabled"] == .bool(false))
        await #expect(throws: ClaudeConversationRuntime.Refused.self) { try await f.request("claude_enable") }
        // Losing a credential does not erase the saved dialogue or grant any model access.
        #expect(try await f.request("chat_history")["turns"] == .array([]))
    }
}
