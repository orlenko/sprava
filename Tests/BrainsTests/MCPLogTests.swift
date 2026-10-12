@testable import Brains
import Darwin
import Foundation
import Testing

/// What the MCP log records of a line: only method names Sprava knows. Invented data only.
@Suite(.serialized) struct MCPLogTests {
    // MARK: - 10. MCP logs name only known methods

    @Test func mcpLogsCarryOnlyKnownMethodNames() {
        #expect(MCPServer.loggedMethod(#"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#) == "tools/call")
        #expect(MCPServer.loggedMethod(#"{"jsonrpc":"2.0","id":1,"method":"x\nmcp client=other auth=ok invented text"}"#) == "unknown_method")
        #expect(MCPServer.loggedMethod(#"{"jsonrpc":"2.0","id":1,"method":7}"#) == "unknown_method")
        #expect(MCPServer.loggedMethod("not json") == "unknown_method")
    }
}
