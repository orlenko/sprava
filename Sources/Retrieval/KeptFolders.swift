import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// Folders the person chose in Settings. A copied or replacement binder does not inherit another
/// binder's selections from a catalog or a reused filesystem path.
public struct KeptFolders: Sendable {
    private let store: StateStore
    public init(support: URL) throws {
        store = try StateStore.open(support.appendingPathComponent("retrieval/kept-folders.sqlite"), schema: .init(version: 1, statements: [
            "CREATE TABLE folders (binder TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY(binder,path)) WITHOUT ROWID"
        ]))
    }

    private func key(_ binder: URL) throws -> String {
        var info = stat()
        guard lstat(binder.resolvingSymlinksInPath().path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw BinderIndex.Failure("The binder could not be opened.")
        }
        return "\(info.st_dev)/\(info.st_ino)/\(info.st_birthtimespec.tv_sec)/\(info.st_birthtimespec.tv_nsec)"
    }

    public func selected(in binder: URL) throws -> [String] {
        let id = try key(binder)
        return try store.read { try $0.rows("SELECT path FROM folders WHERE binder=? ORDER BY path", .text(id)).compactMap { $0.first?.text } }
    }

    static func eligible(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, !["intake", "scripts", ".sprava"].contains(DocumentPaths.fold(String(first))) else { return false }
        return DocumentPaths.isSafe("kept/" + path, forFiling: false) && !parts.contains { DocumentPaths.isKeyFile(String($0)) }
    }

    private func openBinder(_ binder: URL) throws -> Int32 {
        let fd = Darwin.open(binder.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw BinderIndex.Failure("The binder could not be opened.") }
        return fd
    }

    public func set(_ path: String, kept: Bool, in binder: URL) throws {
        let id = try key(binder)
        if kept {
            guard Self.eligible(path) else { throw BinderIndex.Failure("Choose an ordinary folder inside the binder, outside intake.") }
            let root = try openBinder(binder)
            defer { Darwin.close(root) }
            let fd = openat(root, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw BinderIndex.Failure("Choose an existing folder inside the binder.") }
            Darwin.close(fd)
            try store.write { db in
                let count = try db.rows("SELECT count(*) FROM folders WHERE binder=? AND path!=?", .text(id), .text(path)).first?.first?.integer ?? 0
                guard count < 100 else { throw BinderIndex.Failure("This binder already has 100 selected folders.") }
                try db.execute("INSERT OR IGNORE INTO folders VALUES (?,?)", .text(id), .text(path))
            }
        } else {
            _ = try store.write { try $0.execute("DELETE FROM folders WHERE binder=? AND path=?", .text(id), .text(path)) }
        }
    }

    /// Walk only real directories. The reader reopens each regular file beneath the binder with no links.
    func files(in binder: URL, excluding filed: Set<String>, cancelled: () -> Bool) throws -> [String] {
        let root = try openBinder(binder)
        defer { Darwin.close(root) }
        var todo = try selected(in: binder), visited = Set<String>(), files = Set<String>(), seen = 0
        while let relative = todo.popLast() {
            guard Self.eligible(relative), visited.insert(relative).inserted else { continue }
            let fd = openat(root, relative, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            if fd < 0, errno == ENOENT || errno == ELOOP || errno == ENOTDIR { continue }
            guard fd >= 0 else { throw BinderIndex.Failure("A selected folder could not be opened.") }
            guard let dir = fdopendir(fd) else { Darwin.close(fd); throw BinderIndex.Failure("A selected folder could not be listed.") }
            defer { closedir(dir) }
            while true {
                errno = 0
                guard let entry = readdir(dir) else {
                    if errno != 0 { throw BinderIndex.Failure("A selected folder could not be fully listed.") }
                    break
                }
                seen += 1
                guard seen <= 50_000, !cancelled() else { throw BinderIndex.Failure("The selected folders could not be fully checked.") }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }
                guard let name, !name.hasPrefix(".") else { continue }
                let path = relative + "/" + name
                guard Self.eligible(path) else { continue }
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }
                    throw BinderIndex.Failure("A file in a selected folder could not be checked.")
                }
                switch st.st_mode & S_IFMT {
                case S_IFDIR: todo.append(path)
                case S_IFREG where !filed.contains(DocumentPaths.fold(path)):
                    files.insert(path)
                    guard files.count <= 4_000 else { throw BinderIndex.Failure("The selected folders contain more than 4,000 unfiled documents.") }
                default: break
                }
            }
        }
        return files.sorted()
    }
}

extension BinderIndex {
    public func refreshKeptFolders(_ settings: KeptFolders, teka: Teka, reader: any DocumentReader,
                                   cancelled: () -> Bool = { false }) throws {
        let filed = Set(Self.documents(in: teka).map { DocumentPaths.fold($0.path) })
        let paths = try settings.files(in: teka.folder, excluding: filed, cancelled: cancelled)
        let remaining = Set(paths), indexed = try indexedRevisions()
        for source in indexed.keys {
            if case .keptFile(let path) = source, !remaining.contains(path) { try remove(source) }
        }
        for path in paths {
            guard !cancelled() else { throw Failure("The selected folders could not be fully checked.") }
            let source = PassageSource.keptFile(path)
            try update(DocumentRecord(id: .string(path), path: path), reader: reader, indexed: indexed[source], source: source)
        }
    }
}
