import Foundation
import SpravaKit

/// The hosts a binder's Claude may reach without asking (conversation.md 18.3.1), kept beside the connection's consent: one
/// row per connection and host, with whether its commands may use it too. Changing the sharing choices keeps them;
/// disconnecting clears them.
extension ClaudeReadConnections {
    package struct Site: Sendable, Equatable {
        package let host: String
        /// Whether a command may reach it, or only Claude itself, reading.
        package let commands: Bool
        package let added: Date
    }
    package static let maximumSites = 200
    static let sitesTable = "CREATE TABLE IF NOT EXISTS claude_allowed_sites (id TEXT NOT NULL, host TEXT NOT NULL, commands INTEGER NOT NULL CHECK(commands IN (0, 1)), added REAL NOT NULL, PRIMARY KEY (id, host)) STRICT"

    package func sites(_ connection: Connection) throws -> [Site] {
        try state.read { t in
            try t.rows("SELECT host, commands, added FROM claude_allowed_sites WHERE id = ? ORDER BY host", .text(connection.id.uuidString)).map { row in
                guard row.count == 3, let host = row[0].text, AgentEgressProxy.canonical(host) == host,
                      let commands = row[1].integer, [0, 1].contains(commands), let added = row[2].real else { throw Refused.damagedState }
                return Site(host: host, commands: commands == 1, added: Date(timeIntervalSince1970: added))
            }
        }
    }

    /// Whether `caller` may reach `host` in this binder without asking.
    package func allowsSite(_ connection: Connection, host: String, caller: AgentEgressProxy.Caller) throws -> Bool {
        try state.read { t in
            try !t.rows("SELECT 1 FROM claude_allowed_sites WHERE id = ? AND host = ? AND commands >= ?",
                        .text(connection.id.uuidString), .text(host), .integer(caller == .command ? 1 : 0)).isEmpty
        }
    }

    /// Always for this binder. A grant for commands covers Claude too, and one for Claude alone never narrows it.
    package func allowSite(_ connection: Connection, host: String, commands: Bool, now: Date = Date()) throws {
        guard AgentEgressProxy.canonical(host) == host, !AgentEgressProxy.isVendor(host) else { throw Refused.damagedState }
        try state.write { t in
            let id = connection.id.uuidString
            guard try t.rows("SELECT 1 FROM claude_read_connections WHERE id = ? AND generation = ? AND enabled = 1",
                             .text(id), .text(connection.generation.uuidString)).count == 1 else { throw Refused.changed }
            let existing = try t.rows("SELECT 1 FROM claude_allowed_sites WHERE id = ? AND host = ?", .text(id), .text(host))
            if existing.isEmpty {
                guard let count = try t.rows("SELECT count(*) FROM claude_allowed_sites WHERE id = ?", .text(id)).first?.first?.integer,
                      count < Self.maximumSites else { throw Refused.tooManySites }
            }
            try t.execute("""
                INSERT INTO claude_allowed_sites VALUES (?, ?, ?, ?)
                ON CONFLICT(id, host) DO UPDATE SET commands = max(commands, excluded.commands)
                """, .text(id), .text(host), .integer(commands ? 1 : 0), .real(now.timeIntervalSince1970))
        }
    }

    package func removeSite(_ connection: Connection, host: String) throws {
        _ = try state.write { try $0.execute("DELETE FROM claude_allowed_sites WHERE id = ? AND host = ?", .text(connection.id.uuidString), .text(host)) }
    }
}
