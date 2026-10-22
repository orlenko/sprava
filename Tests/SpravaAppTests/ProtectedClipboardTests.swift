import AppKit
@testable import SpravaApp
import Testing

@MainActor
@Suite struct ProtectedClipboardTests {
    @Test func theCredentialIsMarkedPrivateAndExpires() async throws {
        let board = NSPasteboard(name: .init("sprava-invented-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(ProtectedClipboard.copy("invented-registration", to: board, lifetime: .milliseconds(10)))
        #expect(board.string(forType: .string) == "invented-registration")
        #expect(board.types?.contains(ProtectedClipboard.concealed) == true)
        #expect(board.types?.contains(ProtectedClipboard.transient) == true)
        // The expiry runs on the main actor, which the app's other tests share while the suite runs in parallel; there
        // it has come 9 s late. The wait ends as soon as the credential is gone, so the long bound costs a passing run nothing.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while board.string(forType: .string) != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(board.string(forType: .string) == nil)
    }

    @Test func expiryPreservesSomethingCopiedAfterTheCredential() async throws {
        let board = NSPasteboard(name: .init("sprava-invented-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(ProtectedClipboard.copy("invented-registration", to: board, lifetime: .milliseconds(10)))
        board.clearContents()
        #expect(board.setString("invented-later-copy", forType: .string))
        try await Task.sleep(for: .milliseconds(100))
        #expect(board.string(forType: .string) == "invented-later-copy")
    }
}
