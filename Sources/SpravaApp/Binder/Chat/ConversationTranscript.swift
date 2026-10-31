import Foundation
import SpravaKit

/// Only visible answer fields enter a transcript; provider frames and hidden context have no path here.
@MainActor
enum ConversationTranscript {
    static func text(rows: [JSONValue], entries: [BinderChat.Entry], cards: [UUID: ClaudeBinderConversation.Card]) throws -> String {
        var chunks: [String] = [], requests = Set<UUID>(), turns = Set<UUID>(), bytes = 0
        func add(_ label: String, _ text: String) throws {
            let chunk = label + "\n" + text
            bytes += chunk.utf8.count + 2
            guard bytes <= 96 * 1024 * 1024 else { throw ConversationSharing.Failure.incomplete }
            chunks.append(chunk)
        }
        for row in rows {
            guard let request = row["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)), requests.insert(request).inserted,
                  let turn = row["turn_id"]?.stringValue.flatMap(UUID.init(uuidString:)), turns.insert(turn).inserted,
                  let line = row["text"]?.stringValue, let phase = row["phase"]?.stringValue else { throw ConversationSharing.Failure.incomplete }
            try add("You", line)
            if phase == "replied" {
                guard let raw = row["reply"]?.stringValue, let parsed = try? JSONParser.parse(raw), parsed.safety.isSafe,
                      let answer = parsed.value["answer"]?.stringValue else { throw ConversationSharing.Failure.incomplete }
                try add("Claude", answer + suggestions(parsed.value, card: cards[turn]))
            } else {
                let status: String
                switch phase {
                case "accepted", "running": status = "[Reply generating at export snapshot; incomplete.]"
                case "interrupted": status = "[Reply interrupted; incomplete.]"
                case "failed": status = "[Reply failed; incomplete.]"
                default: throw ConversationSharing.Failure.incomplete
                }
                let partial = entries.first { $0.id == turn && $0.speaker == .binder }?.text ?? ""
                try add("Claude", partial + (partial.isEmpty ? "" : "\n\n") + status)
            }
        }
        // On-screen requests not yet accepted have no durable receipt. The composer itself is never read.
        for (index, entry) in entries.enumerated() where entry.speaker == .person && entry.state != .earlier {
            guard let request = entry.requestID, !requests.contains(request) else { continue }
            requests.insert(request)
            try add("You", entry.text + "\n[Request not in the saved snapshot; delivery unconfirmed.]")
            if index + 1 < entries.count, entries[index + 1].speaker == .binder {
                let reply = entries[index + 1]
                let status = reply.state == .replied ? "" : "\n[Reply incomplete at export snapshot.]"
                try add("Claude", reply.text + suggestions(.null, card: cards[reply.id]) + status)
            }
        }
        return chunks.isEmpty ? "No messages in this conversation.\n" : chunks.joined(separator: "\n\n") + "\n"
    }
    private static func suggestions(_ data: JSONValue, card: ClaudeBinderConversation.Card?) -> String {
        var parts: [String] = []
        let citations = (data["citations"]?.arrayValue ?? []).compactMap { source -> String? in
            guard let path = source["path"]?.stringValue else { return nil }
            return path + (source["page"]?.numberValue?.safeInteger.map { ", page \($0)" } ?? "")
        }
        if !citations.isEmpty { parts.append("Sources:\n" + citations.joined(separator: "\n")) }
        if let title = card?.taskTitle ?? data["task"]?["title"]?.stringValue {
            var task = "Suggested To-do:\n" + title + "\n" + (card?.taskDetails ?? data["task"]?["details"]?.stringValue ?? "")
            let due = card?.due ?? data["task"]?["due"]?.stringValue ?? ""
            if !due.isEmpty { task += "\nDue: " + due }
            task += "\nPriority: " + (card?.priority ?? data["task"]?["priority"]?.stringValue ?? "normal")
            parts.append(task)
        }
        if let to = card?.to ?? data["draft"]?["to"]?.stringValue {
            parts.append("Email draft — not sent\nTo: " + to + "\nSubject: " + (card?.subject ?? data["draft"]?["subject"]?.stringValue ?? "")
                         + "\n\n" + (card?.body ?? data["draft"]?["body"]?.stringValue ?? ""))
        }
        return parts.isEmpty ? "" : "\n\n" + parts.joined(separator: "\n\n")
    }
}
