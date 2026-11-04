import BinderFormat
import Clerk
import Darwin
import Foundation
import SpravaKit

/// The built-in IMAP intake's explicit local configuration: which account and which folder or label feed a
/// binder's intake. The account's password stays in `IMAPPasswords`; this store keeps no secret.
/// No binder file can enable an importer or choose an executable/configuration file.
public final class BinderIMAPConnections: Sendable {
    public enum Refused: Error { case invalidConfiguration, changed, damagedState, unavailable }
    public struct Configuration: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        public let id: UUID
        public let folder: URL
        public let account: IMAPAccount
        public let mailbox: String
        public let sender: String
        public let subject: String
        public let search: String
        public let includeExisting: Bool
        public let programHash: String
        public var enabled: Bool
        fileprivate let instance: String
        /// The person's other addresses, lower case; absent in a row written before they could be given.
        fileprivate let otherAddresses: [String]?
        /// Addresses the person writes from besides the account's own name, so their own mail proposes no to-dos.
        public var ownAddresses: [String] { otherAddresses ?? [] }
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

    /// At most this many other addresses per connection.
    public static let maxOwnAddresses = 16

    public func configure(folder: URL, account: IMAPAccount, mailbox: String, sender: String = "", subject: String = "", search: String = "",
                          includeExisting: Bool = true, ownAddresses: [String] = []) throws -> Configuration {
        let folder = folder.resolvingSymlinksInPath()
        // Each one a single well-formed address, kept lower case and once.
        let parsed = ownAddresses.map(MailAddress.single)
        let others = parsed.compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !parsed.contains(nil), others.count <= Self.maxOwnAddresses else { throw Refused.invalidConfiguration }
        let instance = try Self.folderIdentity(folder), programHash = try hash()
        guard Teka.read(folder).catalog != nil, !Teka.expungePending(in: folder), !account.user.isEmpty, !mailbox.isEmpty,
              mailbox.utf8.count <= 1_024, sender.utf8.count <= 256, subject.utf8.count <= 256, search.utf8.count <= 1_024,
              [mailbox, sender, subject, search].allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw Refused.invalidConfiguration }
        return try state.write { t in
            let old = try t.rows("SELECT configuration FROM imap_connections WHERE instance = ?", .text(instance)).first.flatMap { try Self.decode($0) }
            // The same account, folder and filters keep their cursor and receipts, so reconnecting never imports twice.
            let unchanged = old.map { $0.account == account && $0.mailbox == mailbox && $0.programHash == programHash &&
                $0.sender == sender && $0.subject == subject && $0.search == search && $0.includeExisting == includeExisting } == true
            if old == nil {
                guard let count = try t.rows("SELECT count(*) FROM imap_connections").first?.first?.integer, count < 128 else { throw Refused.unavailable }
            }
            let value = Configuration(id: unchanged ? old!.id : UUID(), folder: folder, account: account,
                mailbox: mailbox, sender: sender, subject: subject, search: search, includeExisting: includeExisting,
                programHash: programHash, enabled: true, instance: instance, otherAddresses: others.isEmpty ? nil : others)
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
              !Teka.expungePending(in: value.folder) else { throw Refused.changed }
        return value.folder
    }
    public func disable(folder: URL) throws {
        guard var value = try configuration(for: folder) else { return }; value.enabled = false
        _ = try state.write { try $0.execute("UPDATE imap_connections SET configuration = ? WHERE instance = ?", .blob(try JSONEncoder().encode(value)), .text(value.instance)) }
    }
    /// The person's own addresses across every binder's connection: each account name that is an address, and the
    /// other addresses they gave. Empty when no connection was ever made or the store cannot be read.
    public static func ownAddresses(support: URL) -> Set<String> {
        guard FileManager.default.fileExists(atPath: support.appendingPathComponent("capture/imap.sqlite").path),
              let store = try? BinderIMAPConnections(support: support) else { return [] }
        return store.ownAddresses()
    }
    public func ownAddresses() -> Set<String> {
        let rows = (try? state.read { try $0.rows("SELECT configuration FROM imap_connections LIMIT 129") }) ?? []
        return rows.reduce(into: Set<String>()) { out, row in
            guard let value = try? Self.decode(row) else { return }
            if let address = MailAddress.single(value.account.user) { out.insert(address) }
            out.formUnion(value.ownAddresses)
        }
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
              value.folder.isFileURL, value.folder.path.hasPrefix("/"), value.folder.path.utf8.count <= 4_096,
              !value.account.user.isEmpty, !value.mailbox.isEmpty, value.mailbox.utf8.count <= 1_024,
              value.sender.utf8.count <= 256, value.subject.utf8.count <= 256, value.search.utf8.count <= 1_024, value.programHash.utf8.count <= 128,
              value.ownAddresses.count <= maxOwnAddresses, value.ownAddresses.allSatisfy({ MailAddress.single($0) == $0 }) else { throw Refused.damagedState }
        return value
    }
    private static func folderIdentity(_ folder: URL) throws -> String {
        var info = stat()
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Refused.unavailable }; defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw Refused.unavailable }
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }
}
