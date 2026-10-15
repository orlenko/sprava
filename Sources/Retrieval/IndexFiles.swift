import Darwin
import Foundation
import SpravaKit

/// The index files this installation created, kept outside the binder (binder-v0 §7.2): `.sprava/index.sqlite` is
/// opened only when its device, inode and birth time are listed here, so a file another program planted, or one a
/// restored backup or a copied binder brought, is rebuilt and never opened. `retrieval/indexes.sqlite` in the
/// support folder.
public final class IndexTrust: Sendable {
    struct Identity: Equatable, Sendable { let device: Int64, inode: Int64, birth: Int64 }

    private let store: StateStore

    private init(store: StateStore) { self.store = store }

    public static func open(supportDirectory: URL = SpravaPaths.supportDirectory()) throws -> IndexTrust {
        IndexTrust(store: try StateStore.open(supportDirectory.appendingPathComponent("retrieval/indexes.sqlite"), schema: .init(version: 1, statements: [
            "CREATE TABLE created (device INTEGER NOT NULL, inode INTEGER NOT NULL, birth INTEGER NOT NULL, PRIMARY KEY (device, inode)) WITHOUT ROWID",
        ])))
    }

    func contains(_ id: Identity) throws -> Bool {
        try store.read { t in
            try !t.rows("SELECT 1 FROM created WHERE device = ? AND inode = ? AND birth = ?", .integer(id.device), .integer(id.inode), .integer(id.birth)).isEmpty
        }
    }

    func record(_ id: Identity) throws {
        _ = try store.write { try $0.execute("INSERT OR REPLACE INTO created VALUES (?, ?, ?)", .integer(id.device), .integer(id.inode), .integer(id.birth)) }
    }

    func forget(_ id: Identity) throws {
        _ = try store.write { try $0.execute("DELETE FROM created WHERE device = ? AND inode = ?", .integer(id.device), .integer(id.inode)) }
    }
}

/// A binder's `.sprava` folder, held open: the index is reached only through this handle, never through a link.
final class SpravaFolder {
    let fd: Int32
    /// The folder's real path, read from the handle, for SQLite, which opens by path.
    let path: String

    init(binder: URL) throws {
        let dir = Darwin.open(binder.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { throw BinderIndex.Failure("the binder folder cannot be opened") }
        defer { Darwin.close(dir) }
        let fd = openat(dir, ".sprava", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw BinderIndex.Failure(errno == ENOENT ? "the binder has no .sprava folder; it is not adopted" : "the binder's .sprava is not a folder")
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else {
            Darwin.close(fd)
            throw BinderIndex.Failure("the binder's .sprava folder cannot be located")
        }
        self.fd = fd
        path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    deinit { Darwin.close(fd) }

    /// What stands at `name`, without following a link: its identity, and whether it is a regular file of this user.
    func identity(_ name: String) -> (id: IndexTrust.Identity, plain: Bool)? {
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        let birth = Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec)
        return (.init(device: Int64(st.st_dev), inode: Int64(st.st_ino), birth: birth), st.st_mode & S_IFMT == S_IFREG && st.st_uid == getuid())
    }

    /// A new, empty, private file under a temporary name.
    func createTemporary() throws -> String {
        let name = ".index-\(UUID().uuidString).tmp"
        let file = openat(fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw BinderIndex.Failure("a new index cannot be made in .sprava (\(String(cString: strerror(errno))))") }
        Darwin.close(file)
        return name
    }

    /// Removes a database file with its journal files.
    func remove(_ name: String) {
        for suffix in ["", "-journal", "-wal", "-shm"] { unlinkat(fd, name + suffix, 0) }
    }

    func rename(_ name: String, to target: String) throws {
        guard renameat(fd, name, fd, target) == 0 else { throw BinderIndex.Failure("the new index cannot be put in place (\(String(cString: strerror(errno))))") }
        try AtomicFile.flushToDisk(fd, step: "flush .sprava")
    }
}
