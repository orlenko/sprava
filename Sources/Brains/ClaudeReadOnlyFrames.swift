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
    private var receivedResult = false
    private var interruptAcknowledged = false
    var ended: Bool { receivedResult && (interruptID == nil || interruptAcknowledged) }
    var interruptID: UUID?
    static let maximumReplyBytes = 1024 * 1024

    mutating func receive(_ value: JSONObject) throws {
        guard let type = value["type"]?.stringValue else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
        if let session = value["session_id"], session != .string(sessionID.uuidString.lowercased()) {
            throw ClaudeReadOnlyTurn.Failure.protocolMismatch
        }
        switch type {
        case "system":
            try system(value)
        case "user":
            // Native interruption markers belong to discarded engine context, never app/person history.
            if acknowledged && interruptID != nil { return }
            guard initialized, !acknowledged, value["session_id"] != nil,
                  value["message"]?["role"] == .str("user"),
                  value["parent_tool_use_id"] == nil || value["parent_tool_use_id"] == .null,
                  text(value["message"]?["content"]) == original else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
            acknowledged = true
        case "assistant":
            guard initialized, acknowledged, !receivedResult, safeBlocks(value["message"]?["content"]) else {
                throw ClaudeReadOnlyTurn.Failure.protocolMismatch
            }
        case "stream_event":
            guard initialized, acknowledged, !receivedResult, let event = value["event"]?.objectValue,
                  event["type"]?.stringValue != nil else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
            if let block = event["content_block"], !safeBlocks(.array([block])) { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
            if let blocks = event["message"]?["content"], !safeBlocks(blocks) { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
            if let delta = event["delta"] {
                guard delta.objectValue != nil else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
                let kind = delta["type"]?.stringValue ?? ""
                guard kind != "input_json_delta", !kind.hasPrefix("tool_"), !kind.hasPrefix("mcp_") else {
                    throw ClaudeReadOnlyTurn.Failure.protocolMismatch
                }
            } // Partial data never becomes a final reply, acknowledgment, or permission.
        case "result":
            guard initialized, acknowledged, !receivedResult, value["session_id"] != nil,
                  let failed = value["is_error"]?.boolValue, let subtype = value["subtype"]?.stringValue else {
                throw ClaudeReadOnlyTurn.Failure.protocolMismatch
            }
            if subtype == "success", !failed {
                if let result = value["result"]?.stringValue {
                    guard result.utf8.count <= Self.maximumReplyBytes else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
                    reply = result
                } else if interruptID == nil { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
            } else if !failed || !subtype.hasPrefix("error_") {
                throw ClaudeReadOnlyTurn.Failure.protocolMismatch
            }
            receivedResult = true
        case "control_response":
            guard initialized, let interruptID,
                  value["response"]?["request_id"] == .str(interruptID.uuidString.lowercased()),
                  value["response"]?["subtype"] == .str("success") else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
            interruptAcknowledged = true
        case "rate_limit_event":
            guard initialized else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
        default:
            throw ClaudeReadOnlyTurn.Failure.protocolMismatch
        }
    }

    private mutating func system(_ value: JSONObject) throws {
        guard let subtype = value["subtype"]?.stringValue, subtype.utf8.count <= 128 else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
        if subtype == "init" {
            guard !initialized, value["session_id"] == .str(sessionID.uuidString.lowercased()),
                  value["tools"] == .array([]), value["mcp_servers"] == .array([]),
                  value["permissionMode"] == .str("dontAsk") else { throw ClaudeReadOnlyTurn.Failure.protocolMismatch }
            initialized = true
        } else {
            // CLI 2.1.304 emits ui_invalidate/status and further system telemetry. None establishes
            // readiness or turn success. Unexpected capability activity/scope changes still fail closed.
            guard !["hook_", "tool_", "mcp_", "permission_"].contains(where: subtype.hasPrefix),
                  ["tools", "mcp_servers", "permissionMode"].allSatisfy({ value[$0] == nil }) else {
                throw ClaudeReadOnlyTurn.Failure.protocolMismatch
            }
        }
    }

    private func safeBlocks(_ value: JSONValue?) -> Bool {
        guard let blocks = value?.arrayValue else { return false }
        return blocks.allSatisfy { ["text", "thinking", "redacted_thinking"].contains($0["type"]?.stringValue ?? "") }
    }

    private func text(_ value: JSONValue?) -> String? {
        if let string = value?.stringValue { return string }
        guard let blocks = value?.arrayValue,
              blocks.allSatisfy({ $0["type"] == .str("text") && $0["text"]?.stringValue != nil }) else { return nil }
        return blocks.compactMap { $0["text"]?.stringValue }.joined()
    }
}
