import Brains
import Foundation
import SpravaKit

/// What each turn reached on the web, as the line its summary shows (conversation.md 18.3.1): the hosts, who reached them
/// and the bytes each way, the ones refused, and the searches. Kept by turn in `runtime/turn-sites.sqlite`, beside the
/// conversation it belongs to, and cleared with it. Hosts are for the binder's page, never a log.
final class ClaudeTurnSites: Sendable {
    private let store: StateStore
    private static let schema = StateStore.Schema(version: 1, statements: [
        "CREATE TABLE turn_sites (turn TEXT PRIMARY KEY NOT NULL, conversation TEXT NOT NULL, line TEXT NOT NULL) STRICT",
        "CREATE INDEX turn_sites_conversation ON turn_sites (conversation)"
    ])
    init(at url: URL) throws { store = try StateStore.open(url, schema: Self.schema) }

    func note(conversation: UUID, turn: UUID, uses: [AgentSiteGate.Use], searches: Int) throws {
        guard let line = Self.line(uses, searches: searches) else { return }
        try store.write { t in
            try t.execute("INSERT OR REPLACE INTO turn_sites VALUES (?, ?, ?)", .text(turn.uuidString), .text(conversation.uuidString), .text(line))
        }
    }

    func line(turn: UUID) throws -> String? {
        try store.read { t in try t.rows("SELECT line FROM turn_sites WHERE turn = ?", .text(turn.uuidString)).first?.first?.text }
    }

    func clear(conversation: UUID) throws {
        _ = try store.write { try $0.execute("DELETE FROM turn_sites WHERE conversation = ?", .text(conversation.uuidString)) }
    }

    /// "Reached docs.example.test (Claude, 14 KB in); api.example.test (a command, 3 KB out, 1 KB in). Refused
    /// tracker.example.test. Searched the web 2 times." Nil when the turn reached nothing and searched nothing.
    static func line(_ uses: [AgentSiteGate.Use], searches: Int) -> String? {
        func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        let reached = uses.filter { $0.connections > 0 }.map { use in
            var parts = [use.caller == .agent ? "Claude" : "a command"]
            if use.sent > 0 { parts.append("\(size(use.sent)) out") }
            if use.received > 0 { parts.append("\(size(use.received)) in") }
            return "\(use.host) (\(parts.joined(separator: ", ")))"
        }
        let refused = Array(Set(uses.filter { $0.connections == 0 && $0.refused > 0 }.map(\.host))).sorted()
        var sentences: [String] = []
        if !reached.isEmpty { sentences.append("Reached " + reached.joined(separator: "; ")) }
        if !refused.isEmpty { sentences.append("Refused " + refused.joined(separator: ", ")) }
        if searches > 0 { sentences.append("Searched the web \(searches) time\(searches == 1 ? "" : "s")") }
        return sentences.isEmpty ? nil : sentences.joined(separator: ". ")
    }
}
