import Foundation
import SpravaKit
import Testing
@testable import Brains

@Suite struct ClaudeAuthenticationFramesTests {
    @Test func native401RetriesAreAuthenticationFailuresRatherThanBadProtocol() throws {
        let session = UUID()
        var frames = ClaudeReadOnlyFrames(sessionID: session, original: "Connection check")
        try frames.receive(JSONObject([("type", .str("system")), ("subtype", .str("init")),
            ("session_id", .str(session.uuidString.lowercased())), ("tools", .array([])),
            ("mcp_servers", .array([])), ("permissionMode", .str("dontAsk"))]))
        #expect(throws: ClaudeReadOnlyTurn.Failure.authentication) {
            try frames.receive(JSONObject([("type", .str("system")), ("subtype", .str("api_retry")),
                ("error", .str("authentication_failed")), ("error_status", .int(401))]))
        }
        #expect(!frames.ended && frames.reply == nil)
    }

    @Test func aFailedSuccessEnvelopeCannotBecomeASuccessfulReply() throws {
        let session = UUID()
        var frames = ClaudeReadOnlyFrames(sessionID: session, original: "Connection check")
        try frames.receive(JSONObject([("type", .str("system")), ("subtype", .str("init")),
            ("session_id", .str(session.uuidString.lowercased())), ("tools", .array([])),
            ("mcp_servers", .array([])), ("permissionMode", .str("dontAsk"))]))
        try frames.receive(JSONObject([("type", .str("user")), ("session_id", .str(session.uuidString.lowercased())),
            ("message", .obj([("role", .str("user")), ("content", .str("Connection check"))]))]))
        #expect(throws: ClaudeReadOnlyTurn.Failure.authentication) {
            try frames.receive(JSONObject([("type", .str("result")), ("subtype", .str("success")),
                ("session_id", .str(session.uuidString.lowercased())), ("is_error", .bool(true)),
                ("api_error_status", .int(401)), ("result", .str("invented private error text"))]))
        }
        #expect(frames.reply == nil && !frames.ended)
    }

    @Test func otherNativeApiFailuresEndWithoutAReplyOrPrivateErrorText() throws {
        let session = UUID()
        var frames = ClaudeReadOnlyFrames(sessionID: session, original: "Connection check")
        try frames.receive(JSONObject([("type", .str("system")), ("subtype", .str("init")),
            ("session_id", .str(session.uuidString.lowercased())), ("tools", .array([])),
            ("mcp_servers", .array([])), ("permissionMode", .str("dontAsk"))]))
        try frames.receive(JSONObject([("type", .str("user")), ("session_id", .str(session.uuidString.lowercased())),
            ("message", .obj([("role", .str("user")), ("content", .str("Connection check"))]))]))
        try frames.receive(JSONObject([("type", .str("result")), ("subtype", .str("success")),
            ("session_id", .str(session.uuidString.lowercased())), ("is_error", .bool(true)),
            ("api_error_status", .int(503)), ("result", .str("invented private provider text"))]))
        #expect(frames.ended && frames.reply == nil)
    }
}
