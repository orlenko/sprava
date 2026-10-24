import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// Explicit app consent for a local read/draft conversation. These ids select no binder operations,
/// owner capabilities or imported instructions. A copied binder claim/history is never consulted.
/// Only authenticated app controls may enable/disable; every queued read revalidates its generation
/// and physical folder. Native context must be stopped/cleared before changing or disabling consent.
package final class ClaudeReadConnections: Sendable {
    package enum Refused: Error, Equatable { case unsafeFolder, notABinder, inactive, changed, damagedState, tooManyConnections }
    package struct Connection: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        package let id: UUID
        package let generation: UUID
        package let documents: Bool
        package let intake: Bool
        fileprivate let folder: URL
        fileprivate let instance: String
        package var description: String { "<private Claude read connection>" }
        package var debugDescription: String { description }
    }
    private let state: StateStore
    private static let schema = StateStore.Schema(version: 1, statements: [
        """
        CREATE TABLE claude_read_connections (
            id TEXT PRIMARY KEY NOT NULL,
            generation TEXT NOT NULL,
            folder_instance TEXT UNIQUE NOT NULL,
            folder TEXT NOT NULL,
            documents INTEGER NOT NULL CHECK(documents IN (0, 1)),
            intake INTEGER NOT NULL CHECK(intake IN (0, 1)),
            enabled INTEGER NOT NULL CHECK(enabled IN (0, 1))
        ) STRICT
        """
    ])

    package init(at url: URL) throws { state = try StateStore.open(url, schema: Self.schema) }

    /// The window's explicit consent to share this binder's conversation/tasks and optional documents/intake.
    /// It grants reads/drafts only; a task suggestion still needs the person's existing app action.
    package func enable(folder: URL, documents: Bool, intake: Bool) throws -> Connection {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        let instance = try Self.instance(folder)
        guard Teka.read(folder).catalog != nil, !Teka.expungePending(in: folder) else { throw Refused.notABinder }
        return try state.write { t in
            let rows = try t.rows("SELECT \(Self.columns) FROM claude_read_connections WHERE folder_instance = ? LIMIT 2", .text(instance))
            guard rows.count <= 1 else { throw Refused.damagedState }
            let existing = try rows.first.map(Self.decode)
            if existing == nil {
                guard let count = try t.rows("SELECT count(*) FROM claude_read_connections").first?.first?.integer,
                      count < 128 else { throw Refused.tooManyConnections }
            }
            let id = existing?.connection.id ?? UUID(), generation = UUID()
            try t.execute("""
                INSERT INTO claude_read_connections VALUES (?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT(folder_instance) DO UPDATE SET generation = excluded.generation, folder = excluded.folder,
                    documents = excluded.documents, intake = excluded.intake, enabled = 1
                """, .text(id.uuidString), .text(generation.uuidString), .text(instance), .text(folder.path),
                .integer(documents ? 1 : 0), .integer(intake ? 1 : 0))
            return Connection(id: id, generation: generation, documents: documents, intake: intake,
                              folder: folder, instance: instance)
        }
    }

    /// Read-only lookup for the app's selected folder; no permission is created or widened by lookup.
    package func connection(for folder: URL) throws -> Connection? {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath(), instance = try Self.instance(folder)
        return try state.read { t in
            let rows = try t.rows("SELECT \(Self.columns) FROM claude_read_connections WHERE folder_instance = ? LIMIT 2", .text(instance))
            guard rows.count <= 1 else { throw Refused.damagedState }
            guard let row = rows.first else { return nil }
            let value = try Self.decode(row)
            guard value.enabled else { return nil }
            // A move is made explicit by Enable again. It keeps the opaque id and rotates consent.
            guard value.connection.folder == folder else { throw Refused.changed }
            return value.connection
        }
    }

    /// Trusted runtime lifecycle checks only; this does not enable anything or inspect binder files.
    package func activeConnections() throws -> [Connection] {
        try state.read { t in
            try t.rows("SELECT \(Self.columns) FROM claude_read_connections WHERE enabled = 1").map { try Self.decode($0).connection }
        }
    }

    /// Display-only identity for the person's saved local conversation, including a disconnected or
    /// moved instance. It grants no current read/model/operation permission; currentFolder still fences reads.
    package func savedID(for folder: URL) throws -> UUID? {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath(), instance = try Self.instance(folder)
        return try state.read { t in
            let rows = try t.rows("SELECT \(Self.columns) FROM claude_read_connections WHERE folder_instance = ? LIMIT 2", .text(instance))
            guard rows.count <= 1 else { throw Refused.damagedState }
            return try rows.first.map { try Self.decode($0).connection.id }
        }
    }

    /// Called when queued work actually begins, not merely when the user pressed Send.
    package func currentFolder(_ connection: Connection) throws -> URL {
        try state.read { t in
            let rows = try t.rows("SELECT \(Self.columns) FROM claude_read_connections WHERE id = ? LIMIT 2", .text(connection.id.uuidString))
            guard rows.count == 1 else { throw Refused.inactive }
            let current = try Self.decode(rows[0])
            guard current.enabled else { throw Refused.inactive }
            guard current.connection == connection, try Self.instance(connection.folder) == connection.instance,
                  !Teka.expungePending(in: connection.folder) else { throw Refused.changed }
            return connection.folder
        }
    }

    /// Caller holds its session barrier first. New work is refused even if an old handle was cached.
    package func disable(_ connection: Connection) throws {
        try state.write { t in
            guard try t.execute("UPDATE claude_read_connections SET enabled = 0, generation = ? WHERE id = ? AND generation = ?",
                                .text(UUID().uuidString), .text(connection.id.uuidString), .text(connection.generation.uuidString)) == 1 else {
                throw Refused.changed
            }
        }
    }

    /// Account replacement is not consent to send an existing binder to a different account.
    /// The runtime fences all sessions first; the person then enables each binder again.
    package func disableAll() throws {
        _ = try state.write { try $0.execute("UPDATE claude_read_connections SET enabled = 0, generation = ?", .text(UUID().uuidString)) }
    }

    private static let columns = "id, generation, folder_instance, folder, documents, intake, enabled"
    private static func decode(_ row: [StateValue]) throws -> (connection: Connection, enabled: Bool) {
        guard row.count == 7, let id = row[0].text.flatMap(UUID.init(uuidString:)),
              let generation = row[1].text.flatMap(UUID.init(uuidString:)),
              let instance = row[2].text, instance.utf8.count <= 128,
              let path = row[3].text, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4_096,
              let documents = row[4].integer, [0, 1].contains(documents),
              let intake = row[5].integer, [0, 1].contains(intake),
              let enabled = row[6].integer, [0, 1].contains(enabled) else { throw Refused.damagedState }
        return (Connection(id: id, generation: generation, documents: documents == 1, intake: intake == 1,
                           folder: URL(fileURLWithPath: path), instance: instance), enabled == 1)
    }

    private static func instance(_ folder: URL) throws -> String {
        guard folder.isFileURL, folder.path.utf8.count <= 4_096 else { throw Refused.unsafeFolder }
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Refused.unsafeFolder }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o022 == 0 else { throw Refused.unsafeFolder }
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }
}
