import BinderStore
@testable import Brains
import Darwin
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regression tests for the Codex review of PR #2. Invented data only.
@Suite(.serialized) struct CodexReviewTests {
    @Test func aBrainCannotWriteCardsIntoABinderAnotherMacOwns() throws {
        let s = try pSetup()
        let client = MCPClientRecord(id: "c1", name: "c", tokenSHA256: "", binders: [s.folder.standardizedFileURL.path: "propose"], createdAt: "", revoked: false)
        let other = Commands(support: s.support, deviceID: "another-mac")
        let server = MCPServer(client: client, commands: other, shelf: { Shelf.rows(registry: nil, picked: [s.folder]) }, now: { pNow })
        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
        let r = try JSONParser.parse(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"estate-example","title":"x","ops":[{"op":"add_log_entry","args":{"entry":{"action":"noted","title":"x","date":"2026-10-06"}}}]}}}"#)!).value
        #expect(r["result"]?["isError"] == .bool(true))
        #expect(pOpen(s).isEmpty)
    }
}
