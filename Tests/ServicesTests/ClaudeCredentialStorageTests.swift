import Foundation
import Security
@testable import Services
import SpravaKit
import Testing

@Suite struct ClaudeCredentialStorageTests {
    @Test func anUnprovisionedRuntimeCanKeepOnlyThisRunsExplicitlyEnteredToken() throws {
        func storage() -> ClaudeCredentialStorage {
            .init(load: { (errSecMissingEntitlement, nil) }, save: { _ in errSecMissingEntitlement })
        }
        let first = storage()
        #expect(try first.read() == nil)
        try first.replace("invented-token")
        #expect(try first.read() == "invented-token"); #expect(!first.persistent)
        #expect(try storage().read() == nil) // A restarted process does not pretend to have a token.
        try first.replace(nil); #expect(try first.read() == nil)
    }
    @Test func lockedOrDamagedKeychainsCannotSilentlyDowngradeCredentialStorage() throws {
        for refusal in [errSecInteractionNotAllowed, errSecDecode] {
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
