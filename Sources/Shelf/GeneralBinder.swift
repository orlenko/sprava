import Darwin
import Foundation
import SpravaKit

/// The one built-in ordinary binder (D26). Reading its binding never creates state or a binder.
public struct GeneralBinder: Sendable {
    private let database: URL
    private static let schema = StateStore.Schema(version: 1, statements: [])

    public init(support: URL) { database = support.appendingPathComponent("shelf/general.sqlite") }

    private struct Binding: Codable {
        let path: String
        let device: Int32
        let inode: UInt64
        let born: Int64
        let nanos: Int64

        init(_ folder: URL) throws {
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Unavailable() }
            path = folder.path
            device = info.st_dev; inode = info.st_ino
            born = Int64(info.st_birthtimespec.tv_sec); nanos = Int64(info.st_birthtimespec.tv_nsec)
        }

        func matches(_ folder: URL) -> Bool {
            guard let other = try? Binding(folder.resolvingSymlinksInPath()) else { return false }
            return device == other.device && inode == other.inode && born == other.born && nanos == other.nanos
        }
    }

    public struct Unavailable: Error, CustomStringConvertible {
        public var description: String { "General's folder is missing or has changed. Restore its original folder before using General again; no replacement was created." }
    }

    /// Serialized across runtime/CLI processes. Creation accepts no user content: only the committed binding
    /// is returned to callers that will save a note or item. A failed creation never adopts an existing folder.
    public func ensure(create: () throws -> URL) throws -> URL {
        let store = try StateStore.open(database, schema: Self.schema)
        return try store.write { transaction in
            if let binding = try transaction.document(Binding.self, key: "general") {
                let folder = URL(fileURLWithPath: binding.path, isDirectory: true)
                guard (try? Binding(folder)) != nil, binding.matches(folder) else { throw Unavailable() }
                return folder
            }
            let folder = try create().resolvingSymlinksInPath().standardizedFileURL
            try transaction.setDocument(Binding(folder), key: "general")
            return folder
        }
    }

    /// Path and physical identity both count, so an alias cannot retire General. Damaged state throws;
    /// lifecycle callers must refuse the operation before stopping sessions or deleting their history.
    public func protects(_ folder: URL) throws -> Bool {
        guard try StateDirectory.open(database.deletingLastPathComponent()) != nil else { return false }
        var info = stat()
        guard lstat(database.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw Unavailable()
        }
        let store = try StateStore.open(database, schema: Self.schema)
        return try store.read { transaction in
            guard let binding = try transaction.document(Binding.self, key: "general") else { return false }
            return folder.standardizedFileURL.path == binding.path || binding.matches(folder)
        }
    }
}
