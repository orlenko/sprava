import Brains
import Foundation
import SpravaKit

/// The binder's sites and the questions about new ones (conversation.md 18.3.1): a turn's gate reads and keeps the binder's
/// list, `chat_poll` carries its question, `chat_site_answer` takes the person's tap, and the binder's Claude settings list
/// and remove sites. Hosts go to the app and the binder's list only, never to a log.
extension ClaudeConversationRuntime {
    nonisolated func siteGate(scope: ClaudeReadConnections.Connection, asks: Bool) -> AgentSiteGate {
        let connections = self.connections
        return AgentSiteGate(asks: asks, listed: { host, caller in
            (try? connections.allowsSite(scope, host: host, caller: caller)) == true
        }, remember: { host, caller in
            (try? connections.allowSite(scope, host: host, commands: caller == .command)) != nil
        })
    }

    static func siteQuestionJSON(_ question: AgentSiteGate.Question) -> JSONValue {
        .obj([("id", .str(question.id.uuidString)), ("host", .str(question.host)), ("by_command", .bool(question.caller == .command))])
    }

    /// The person's tap on the running turn's question; `answered` false when it was no longer asked.
    func answerSite(_ request: JSONObject, scope: ClaudeReadConnections.Connection, turn: UUID) -> JSONObject {
        guard let id = request["question_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let answer = request["answer"]?.stringValue.flatMap(AgentSiteGate.Answer.init(rawValue:)),
              let current = active[scope.id], current.turn == turn, let gate = current.gate else {
            return .init([(key: "answered", value: .bool(false))])
        }
        return .init([(key: "answered", value: .bool(gate.answer(id, answer)))])
    }

    /// `chat_sites` lists the binder's sites; `chat_site_remove` removes one and lists what is left.
    func sites(_ command: String, _ request: JSONObject, scope: ClaudeReadConnections.Connection) throws -> JSONObject {
        if command == "chat_site_remove" {
            guard let host = request["host"]?.stringValue, host.utf8.count <= 253 else { throw Refused.invalidRequest }
            try connections.removeSite(scope, host: host)
        }
        let rows: [JSONValue] = try connections.sites(scope).map { site in
            .obj([("host", .str(site.host)), ("commands", .bool(site.commands)), ("added", .str(ISOTime.string(site.added)))])
        }
        return .init([(key: "sites", value: .array(rows))])
    }
}
