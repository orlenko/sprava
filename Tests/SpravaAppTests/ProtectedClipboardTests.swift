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
        // The expiry runs on the main actor, which the app's other tests share while the suite runs in parallel; there its
        // task has waited about 30 s to start. The wait counts its own turns, so time the actor spends elsewhere uses none.
        for _ in 0..<10_000 where board.string(forType: .string) != nil {
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
