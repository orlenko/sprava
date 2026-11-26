import Darwin
import Foundation
import SpravaKit

/// A built-in ordinary binder (D26, D47): one of a short list, each made on its first use and kept on this Mac's
/// Shelf. Reading its binding never creates state or a binder.
public struct BuiltInBinder: Sendable {
    /// The built-in binders, in the order they are listed: General for what has no binder yet, Improvements for what
    /// the binders could not do or keep doing by hand.
    public enum Kind: String, CaseIterable, Sendable {
        case general, improvements
        /// The name the person reads.
        public var title: String { self == .general ? "General" : "Improvements" }
        /// The folder name a new one is given, made free among the binders beside it.
        public var folderName: String { rawValue }
    }

    public let kind: Kind
    private let database: URL
    private static let schema = StateStore.Schema(version: 1, statements: [])

    /// Every built-in binder's binding lives in one store, by the kind's name; General's key is the one it always had.
    public init(_ kind: Kind = .general, support: URL) {
        self.kind = kind
        database = support.appendingPathComponent("shelf/general.sqlite")
    }

    /// The built-in binder `folder` is, if any. Damaged state throws, as `protects` does.
    public static func kind(of folder: URL, support: URL) throws -> Kind? {
        try Kind.allCases.first { try BuiltInBinder($0, support: support).protects(folder) }
    }

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
        public var title = "General"
        public var description: String { "\(title)\u{2019}s folder is missing or has changed. Restore its original folder before using \(title) again; no replacement was created." }
    }

    /// Serialized across runtime/CLI processes. Creation accepts no user content: only the committed binding
    /// is returned to callers that will save a note or item. A failed creation never adopts an existing folder.
    public func ensure(create: () throws -> URL) throws -> URL {
        let store = try StateStore.open(database, schema: Self.schema)
        return try store.write { transaction in
            if let binding = try transaction.document(Binding.self, key: kind.rawValue) {
                let folder = URL(fileURLWithPath: binding.path, isDirectory: true)
                guard (try? Binding(folder)) != nil, binding.matches(folder) else { throw Unavailable(title: kind.title) }
                return folder
            }
            let folder = try create().resolvingSymlinksInPath().standardizedFileURL
            try transaction.setDocument(Binding(folder), key: kind.rawValue)
            return folder
        }
    }

    /// The binder's folder when it was made and is still the folder it was bound to; nil when it was never made. Never
    /// creates state or a binder. A folder that is missing or was replaced throws, as `ensure` does.
    public func folder() throws -> URL? {
        guard try StateDirectory.open(database.deletingLastPathComponent()) != nil else { return nil }
        var info = stat()
        guard lstat(database.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw Unavailable(title: kind.title)
        }
        let store = try StateStore.open(database, schema: Self.schema)
        return try store.read { transaction in
            guard let binding = try transaction.document(Binding.self, key: kind.rawValue) else { return nil }
            let folder = URL(fileURLWithPath: binding.path, isDirectory: true)
            guard (try? Binding(folder)) != nil, binding.matches(folder) else { throw Unavailable(title: kind.title) }
            return folder
        }
    }

    /// Path and physical identity both count, so an alias cannot retire a built-in binder. Damaged state throws;
    /// lifecycle callers must refuse the operation before stopping sessions or deleting their history.
    public func protects(_ folder: URL) throws -> Bool {
        guard try StateDirectory.open(database.deletingLastPathComponent()) != nil else { return false }
        var info = stat()
        guard lstat(database.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw Unavailable(title: kind.title)
        }
        let store = try StateStore.open(database, schema: Self.schema)
        return try store.read { transaction in
            guard let binding = try transaction.document(Binding.self, key: kind.rawValue) else { return false }
            return folder.standardizedFileURL.path == binding.path || binding.matches(folder)
        }
    }
}

/// General, the first built-in binder, by the name its callers know.
public typealias GeneralBinder = BuiltInBinder
