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

    func opened(_ session: UUID) throws -> ClaudeReadOnlyFrames {
        var frames = ClaudeReadOnlyFrames(sessionID: session, original: "Invented line")
        try frames.receive(JSONObject([("type", .str("system")), ("subtype", .str("init")),
            ("session_id", .str(session.uuidString.lowercased())), ("tools", .array([])),
            ("mcp_servers", .array([])), ("permissionMode", .str("dontAsk"))]))
        try frames.receive(JSONObject([("type", .str("user")), ("session_id", .str(session.uuidString.lowercased())),
            ("message", .obj([("role", .str("user")), ("content", .str("Invented line"))]))]))
        return frames
    }

    func result(_ session: UUID, failed: Bool, status: Int? = nil) -> JSONObject {
        JSONObject([("type", .str("result")), ("subtype", .str("success")), ("session_id", .str(session.uuidString.lowercased())),
            ("is_error", .bool(failed)), ("api_error_status", status.map { .int($0) } ?? .null), ("result", .str("Invented reply"))])
    }

    func limit(_ status: String) -> JSONObject {
        JSONObject([("type", .str("rate_limit_event")), ("rate_limit_info", .obj([("status", .str(status))]))])
    }

    /// An account out of allowance is named as that, by either of the CLI's two signals, so the person can act on it.
    @Test func aTurnThatFailsAtALimitIsAUsageLimit() throws {
        let session = UUID()
        var refused = try opened(session)
        try refused.receive(limit("rejected"))
        #expect(throws: ClaudeReadOnlyTurn.Failure.usageLimit) { try refused.receive(result(session, failed: true)) }
        var status = try opened(session)
        #expect(throws: ClaudeReadOnlyTurn.Failure.usageLimit) { try status.receive(result(session, failed: true, status: 429)) }
    }

    /// A refused allowance alone is no failure: the turn may still answer. Nearing a limit is not reaching it.
    @Test func aLimitEventDoesNotFailATurnThatAnswers() throws {
        let session = UUID()
        var refused = try opened(session)
        try refused.receive(limit("rejected"))
        try refused.receive(result(session, failed: false))
        #expect(refused.reply == "Invented reply")
        var warned = try opened(session)
        try warned.receive(limit("allowed_warning"))
        try warned.receive(result(session, failed: true))
        #expect(warned.ended && warned.reply == nil)
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

    /// The same refusal after a tool ran says so, because the turn may have changed something and must not simply start again.
    @Test func aLimitAfterAToolIsNotTheLimitBeforeOne() throws {
        let id = UUID(), text = id.uuidString.lowercased()
        func frame(_ json: String) throws -> JSONObject { try #require(JSONParser.parse(json).value.objectValue) }
        var frames = ClaudeReadOnlyFrames(sessionID: id, original: "Tidy", tools: ["Bash"])
        try frames.receive(frame(#"{"type":"system","subtype":"init","session_id":"\#(text)","tools":["Bash"],"mcp_servers":[],"permissionMode":"default"}"#))
        try frames.receive(frame(#"{"type":"user","session_id":"\#(text)","parent_tool_use_id":null,"message":{"role":"user","content":"Tidy"}}"#))
        try frames.receive(frame(#"{"type":"assistant","session_id":"\#(text)","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#))
        #expect(throws: ClaudeReadOnlyTurn.Failure.usageLimitMidTurn) {
            try frames.receive(frame(#"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"session_id":"\#(text)"}"#))
        }
    }
}
