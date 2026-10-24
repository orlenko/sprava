import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// The built-in IMAP intake plugin's explicit local configuration. Credentials remain in the
/// person's selected private .env file; this store keeps only its path and filesystem fingerprint.
/// No binder file can enable an importer or choose an executable/configuration file.
public final class BinderIMAPConnections: Sendable {
    public enum Refused: Error { case invalidConfiguration, changed, damagedState, unavailable }
    public struct Configuration: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        public let id: UUID
        public let folder: URL
        public let environment: URL
        public let mailbox: String
        public let sender: String
        public let subject: String
        public let search: String
        public let port: Int
        public let startTLS: Bool
        public let includeExisting: Bool
        public let programHash: String
        public var enabled: Bool
        fileprivate let instance: String
        fileprivate let environmentStamp: String
        public var description: String { "<private binder IMAP configuration>" }
        public var debugDescription: String { description }
    }
    private let state: StateStore
    private let hash: @Sendable () throws -> String
    private static let schema = StateStore.Schema(version: 1, statements: [
        "CREATE TABLE imap_connections (instance TEXT PRIMARY KEY, configuration BLOB NOT NULL) STRICT",
        "CREATE TABLE imap_imports (connection TEXT NOT NULL, validity INTEGER NOT NULL, uid INTEGER NOT NULL, path TEXT NOT NULL, PRIMARY KEY(connection, validity, uid)) STRICT"
    ])
    public convenience init(support: URL) throws { try self.init(support: support, hash: IMAPNativeFetch.programHash) }
    package init(support: URL, hash: @escaping @Sendable () throws -> String) throws { self.hash = hash; state = try StateStore.open(support.appendingPathComponent("capture/imap.sqlite"), schema: Self.schema) }

    public func configure(folder: URL, environment: URL, mailbox: String, sender: String = "", subject: String = "", search: String = "",
                          port: Int = 993, startTLS: Bool = false, includeExisting: Bool = true) throws -> Configuration {
        let folder = folder.resolvingSymlinksInPath(), environment = environment.resolvingSymlinksInPath()
        let instance = try Self.folderIdentity(folder), stamp = try Self.environmentIdentity(environment), programHash = try hash()
        guard Teka.read(folder).catalog != nil, !Teka.expungePending(in: folder), !mailbox.isEmpty,
              mailbox.utf8.count <= 1_024, sender.utf8.count <= 256, subject.utf8.count <= 256, search.utf8.count <= 1_024,
              [mailbox, sender, subject, search].allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              (1...65_535).contains(port), DocumentPaths.isKeyFile(environment.lastPathComponent),
              !DocumentPaths.fold(environment.path).hasPrefix(DocumentPaths.fold(folder.path) + "/") else { throw Refused.invalidConfiguration }
        return try state.write { t in
            let old = try t.rows("SELECT configuration FROM imap_connections WHERE instance = ?", .text(instance)).first.flatMap { try Self.decode($0) }
            let unchanged = old.map { $0.environment == environment && $0.environmentStamp == stamp && $0.mailbox == mailbox &&
                $0.programHash == programHash && $0.sender == sender && $0.subject == subject && $0.search == search && $0.port == port && $0.startTLS == startTLS && $0.includeExisting == includeExisting } == true
            if old == nil {
                guard let count = try t.rows("SELECT count(*) FROM imap_connections").first?.first?.integer, count < 128 else { throw Refused.unavailable }
            }
            let value = Configuration(id: unchanged ? old!.id : UUID(), folder: folder, environment: environment,
                mailbox: mailbox, sender: sender, subject: subject, search: search, port: port, startTLS: startTLS, includeExisting: includeExisting,
                programHash: programHash, enabled: true, instance: instance, environmentStamp: stamp)
            try t.execute("INSERT OR REPLACE INTO imap_connections VALUES (?, ?)", .text(instance), .blob(try JSONEncoder().encode(value)))
            return value
        }
    }
    public func configuration(for folder: URL) throws -> Configuration? {
        let instance = try Self.folderIdentity(folder.resolvingSymlinksInPath())
        return try state.read { try $0.rows("SELECT configuration FROM imap_connections WHERE instance = ?", .text(instance)).first.flatMap { try Self.decode($0) } }
    }
    public func enabled() throws -> [Configuration] {
        try state.read { try $0.rows("SELECT configuration FROM imap_connections LIMIT 129").map(Self.decode).filter(\.enabled) }
    }
    public func current(_ value: Configuration) throws -> URL {
        guard let current = try configuration(for: value.folder), current == value, current.enabled,
              try Self.environmentIdentity(value.environment) == value.environmentStamp,
              !Teka.expungePending(in: value.folder) else { throw Refused.changed }
        return value.folder
    }
    public func disable(folder: URL) throws {
        guard var value = try configuration(for: folder) else { return }; value.enabled = false
        _ = try state.write { try $0.execute("UPDATE imap_connections SET configuration = ? WHERE instance = ?", .blob(try JSONEncoder().encode(value)), .text(value.instance)) }
    }
    public func imported(_ connection: UUID, validity: UInt32, uid: UInt32) throws -> String? {
        try state.read { try $0.rows("SELECT path FROM imap_imports WHERE connection = ? AND validity = ? AND uid = ?",
                                     .text(connection.uuidString), .integer(Int64(validity)), .integer(Int64(uid))).first?.first?.text }
    }
    public func recordImport(_ connection: UUID, validity: UInt32, uid: UInt32, path: String) throws {
        guard DocumentPaths.isIntake(path), !DocumentPaths.isKeyFile(path) else { throw Refused.invalidConfiguration }
        try state.write { t in
            let old = try t.rows("SELECT path FROM imap_imports WHERE connection = ? AND validity = ? AND uid = ?",
                                .text(connection.uuidString), .integer(Int64(validity)), .integer(Int64(uid))).first?.first?.text
            guard old == nil || old == path else { throw Refused.damagedState }
            try t.execute("INSERT OR IGNORE INTO imap_imports VALUES (?, ?, ?, ?)", .text(connection.uuidString),
                          .integer(Int64(validity)), .integer(Int64(uid)), .text(path))
        }
    }
    private static func decode(_ row: [StateValue]) throws -> Configuration {
        guard row.count == 1, let data = row[0].blob, data.count <= 16 * 1024,
              let value = try? JSONDecoder().decode(Configuration.self, from: data),
              value.folder.isFileURL, value.environment.isFileURL, value.folder.path.hasPrefix("/"), value.environment.path.hasPrefix("/"),
              value.folder.path.utf8.count <= 4_096, value.environment.path.utf8.count <= 4_096,
              (1...65_535).contains(value.port), !value.mailbox.isEmpty, value.mailbox.utf8.count <= 1_024,
              value.sender.utf8.count <= 256, value.subject.utf8.count <= 256, value.search.utf8.count <= 1_024, value.programHash.utf8.count <= 128 else { throw Refused.damagedState }
        return value
    }
    private static func folderIdentity(_ folder: URL) throws -> String {
        var info = stat()
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Refused.unavailable }; defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw Refused.unavailable }
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }
    private static func environmentIdentity(_ file: URL) throws -> String {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Refused.invalidConfiguration }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size <= 128 * 1024 else { throw Refused.invalidConfiguration }
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_size)"
    }
}
