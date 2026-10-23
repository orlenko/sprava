import Foundation
import SpravaKit

/// The tool-free pilot's installed-CLI contract, checked by the invented-binder proof on Claude 2.1.304.
/// A genuine result, the original input acknowledgment, and the same verified session are all required.
/// This does not authorize a launch, authenticate app history, or grant any binder/tool capability.
struct ClaudeReadOnlyFrames {
    let sessionID: UUID
    let original: String
    private(set) var initialized = false
    private(set) var acknowledged = false
    private(set) var reply: String?
    private(set) var ended = false
    var interruptID: UUID?
    static let maximumReplyBytes = 1024 * 1024

    mutating func receive(_ value: JSONObject) throws {
        guard !ended, let type = value["type"]?.stringValue else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
        if let session = value["session_id"], session != .string(sessionID.uuidString.lowercased()) {
            throw ClaudeReadOnlyTurn.Failure.protocolMismatch
        }
        switch type {
        case "system":
            guard value["subtype"] == .str("init"), !initialized,
                  value["session_id"] == .string(sessionID.uuidString.lowercased()),
                  value["tools"] == .array([]), value["mcp_servers"] == .array([]),
                  value["permissionMode"] == .str("dontAsk") else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
            initialized = true
        case "user":
            guard initialized, !acknowledged, value["session_id"] != nil,
                  value["message"]?["role"] == .str("user"),
                  value["parent_tool_use_id"] == nil || value["parent_tool_use_id"] == .null,
                  text(value["message"]?["content"]) == original else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
            acknowledged = true
        case "assistant":
            guard initialized, acknowledged, let blocks = value["message"]?["content"]?.arrayValue,
                  blocks.allSatisfy({ ["text", "thinking", "redacted_thinking"].contains($0["type"]?.stringValue ?? "") }) else {
                throw ClaudeReadOnlyTurn.Failure.protocolMismatch
            }
        case "result":
            guard initialized, acknowledged, value["session_id"] != nil,
                  let failed = value["is_error"]?.boolValue, let subtype = value["subtype"]?.stringValue else {
                throw ClaudeReadOnlyTurn.Failure.protocolMismatch
            }
            if subtype == "success", !failed, let result = value["result"]?.stringValue,
               result.utf8.count <= Self.maximumReplyBytes {
                reply = result
            } else if !failed || !subtype.hasPrefix("error_") {
                throw ClaudeReadOnlyTurn.Failure.protocolMismatch
            }
            ended = true
        case "control_response":
            guard initialized, let interruptID,
                  value["response"]?["request_id"] == .str(interruptID.uuidString.lowercased()),
                  value["response"]?["subtype"] == .str("success") else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
        case "rate_limit_event":
            guard initialized else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
        default:
            throw ClaudeReadOnlyTurn.Failure.protocolMismatch
        }
    }

    private func text(_ value: JSONValue?) -> String? {
        if let string = value?.stringValue { return string }
        guard let blocks = value?.arrayValue,
              blocks.allSatisfy({ $0["type"] == .str("text") && $0["text"]?.stringValue != nil }) else { return nil }
        return blocks.compactMap { $0["text"]?.stringValue }.joined()
    }
}
