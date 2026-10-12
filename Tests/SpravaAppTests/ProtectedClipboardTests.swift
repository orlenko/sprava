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
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
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
