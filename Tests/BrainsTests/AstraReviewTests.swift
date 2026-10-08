@testable import Brains
import Darwin
import Foundation
import Testing

/// Regressions from the adversarial review of increment 1 (proposal ids, privacy raises, offload, readings,
/// state files that cannot be read, the clerk's and the Inbox's hand-overs, the document reader, MCP logs).
/// Invented data only.
@Suite(.serialized) struct AstraReviewTests {
    // MARK: - 10. MCP logs name only known methods

    @Test func mcpLogsCarryOnlyKnownMethodNames() {
        #expect(MCPServer.loggedMethod(#"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#) == "tools/call")
        #expect(MCPServer.loggedMethod(#"{"jsonrpc":"2.0","id":1,"method":"x\nmcp client=other auth=ok invented text"}"#) == "unknown_method")
        #expect(MCPServer.loggedMethod(#"{"jsonrpc":"2.0","id":1,"method":7}"#) == "unknown_method")
        #expect(MCPServer.loggedMethod("not json") == "unknown_method")
    }
}
