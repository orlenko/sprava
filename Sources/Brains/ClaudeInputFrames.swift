import Foundation
import SpravaKit

/// conversation §11.1: encode user lines and interrupt requests for the structured Claude transport.
/// Wire reference: anthropics/claude-agent-sdk-python @ aada02405ede575d7cbf8e6851a8179762560816,
/// client.py query(), _internal/query.py stamp_user_message(), _send_control_request() and interrupt().
/// No runtime registration: before using this, verify the installed, versioned CLI honors client_composed
/// (no @path expansion or slash dispatch), plus ALL confinement/auth/session checks. Encoding is not proof.
public enum ClaudeInputFrames {
    public enum Failure: Error, Sendable, Equatable { case lineTooLarge }
    public static let maximumTextBytes = 4 * 1024 * 1024
    public static let maximumFrameBytes = 8 * 1024 * 1024

    /// Exact text is JSON data, not argv or a command. Session identity comes from trusted runtime state.
    /// This is not durable acceptance or idempotency; the runtime must commit the original line first.
    public static func userLine(_ text: String, sessionID: UUID) throws -> Data {
        guard text.utf8.count <= maximumTextBytes else { throw Failure.lineTooLarge }
        return try frame(.object(JSONObject([
            ("type", .string("user")),
            ("session_id", .string(sessionID.uuidString.lowercased())),
            ("parent_tool_use_id", .null),
            ("client_composed", .bool(true)),
            ("message", .object(JSONObject([("role", .string("user")), ("content", .string(text))])))
        ])))
    }

    /// The driver correlates this control request with its response; sending it alone does not prove Stop.
    public static func interrupt(requestID: UUID) throws -> Data {
        try frame(.object(JSONObject([
            ("type", .string("control_request")),
            ("request_id", .string(requestID.uuidString.lowercased())),
            ("request", .object(JSONObject([("subtype", .string("interrupt"))])))
        ])))
    }

    private static func frame(_ value: JSONValue) throws -> Data {
        let bytes = Data((JSONWriter.compact(value) + "\n").utf8)
        guard bytes.count <= maximumFrameBytes else { throw Failure.lineTooLarge }
        return bytes
    }
}
