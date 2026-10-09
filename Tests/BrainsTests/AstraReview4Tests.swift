import BinderStore
@testable import Brains
import CryptoKit
import Darwin
import Foundation
import Testing

/// Regressions from the fourth adversarial review of increment 1 (key and credential files in intake, hub
/// withdrawal while the outbox fails, private corrections that close items, correction cards that could not be
/// kept, unreadable op logs, exhausted id sequences) and the MCP socket's modes. Invented data only.
@Suite(.serialized) struct AstraReview4Tests {
    // MARK: - 7. The MCP socket's modes come from chmod, never from the process umask

    @Test func theSocketIsPrivateInAPrivateFolder() throws {
        // Short, so the socket path stays under the 104-byte limit.
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sp4-\(UUID().uuidString.prefix(8))")
        let listener = MCPListener(support: support, commands: Commands(support: support, deviceID: "t"), queue: DispatchQueue(label: "test.mcp4"),
                                   shelf: { [] }, log: { _ in })
        try listener.start()
        defer { listener.stop() }
        var st = stat()
        #expect(lstat(listener.socketURL.path, &st) == 0)
        #expect(st.st_mode & S_IFMT == S_IFSOCK)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(lstat(listener.socketURL.deletingLastPathComponent().path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
    }
}
