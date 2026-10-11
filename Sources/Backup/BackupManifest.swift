import BinderFormat
import CryptoKit
import Darwin
import Foundation
import SpravaKit

/// What a snapshot holds, entry by entry, and the binder folder's own metadata (docs/backup.md §6).
extension Backup {
    // MARK: - Manifests

    /// What restic leaves out of every snapshot (docs/backup.md §3.2): the binder lock, temporary files, and the
    /// Finder's view settings, which macOS rewrites on every visit. `manifest` leaves out the same names.
    static let excludes = [".teka.lock", ".*.tmp", ".DS_Store"]

    /// Every entry under `folder` that a snapshot holds, as restic backs it up: a file with its SHA-256, a symbolic
    /// link with its target, a folder as such; files and folders also with their permission bits and extended
    /// attributes, which restic saves and restores on macOS (Finder tags and comments, resource forks, quarantine),
    /// so a change to those alone is a change: "Offload again" takes a new snapshot, and the last check before the
    /// folder leaves sees it. A folder that cannot be listed or an entry that cannot be read throws: whatever a
    /// manifest left out could leave the Mac while the binder still counts as unchanged.
    ///
    /// A file's or folder's modification time counts too, as restic saves and restores it, and so do hard links: a
    /// file that is another link to one listed earlier names it (`hardlink:`), so linking or unlinking two identical
    /// files is a change. A symbolic link's own time is not compared, as restic does not restore it on macOS; nor is
    /// ownership, which a restore by the person (not root) cannot give back. Sockets are left out, as restic leaves
    /// them out.
    ///
    /// Left out are the attributes macOS itself keeps and a restore cannot give back (`volatileAttributes`): they
    /// would make every verification fail, and no person sets them. The binder folder's own metadata is not compared.
    static func manifest(_ folder: URL) throws -> [String: String] { try manifest(folder, afterRead: { _ in }) }

    /// `manifest`, with a hook that runs after each file is hashed and each folder is read; tests land a save there.
    static func manifest(_ folder: URL, afterRead: (URL) -> Void) throws -> [String: String] {
        var out: [String: String] = [:]
        // The first path seen for each file with more than one link, by device and inode.
        var linked: [String: String] = [:]
        func unreadable(_ rel: String) -> Failure {
            Failure(message: "\(rel.isEmpty ? "the binder" : rel) cannot be read; nothing was removed")
        }
        // Everything read counts only when it is still the same, unchanged, once the whole binder was read: each
        // folder (device, inode, times) and each file (also its size) is checked again at the end, so a save into a
        // folder or file read earlier fails the manifest instead of being missed.
        func state(of info: stat) -> [Int] {
            [Int(info.st_dev), Int(info.st_ino), Int(info.st_mode), Int(info.st_size), info.st_mtimespec.tv_sec,
             info.st_mtimespec.tv_nsec, info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec]
        }
        func state(_ url: URL, follow: Bool) -> [Int]? {
            var info = stat()
            guard (follow ? stat(url.path, &info) : lstat(url.path, &info)) == 0 else { return nil }
            return state(of: info)
        }
        var read: [(url: URL, rel: String, follow: Bool, state: [Int])] = []
        func walk(_ dir: URL, _ prefix: String) throws {
            // The binder folder itself may be reached through a link; the folders inside it are read as they are.
            let follow = prefix.isEmpty
            guard let before = state(dir, follow: follow), mode_t(before[2]) & S_IFMT == S_IFDIR else { throw unreadable(prefix) }
            read.append((dir, prefix, follow, before))
            try entries(dir, prefix)
            afterRead(dir)
        }
        func entries(_ dir: URL, _ prefix: String) throws {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { throw unreadable(prefix) }
            for name in names.sorted() {
                // The names restic leaves out (`excludes`), wherever they are, and anything inside them.
                // `.*.tmp` needs two dots of its own: `.tmp` alone is backed up.
                if name == ".teka.lock" || name == ".DS_Store" || (name.utf8.count >= 5 && name.hasPrefix(".") && name.hasSuffix(".tmp")) {
                    continue
                }
                let url = dir.appendingPathComponent(name)
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw unreadable(rel) }
                func metadata() throws -> String {
                    guard let attributes = Self.attributesDigest(url.path) else { throw unreadable(rel) }
                    return " mode:" + String(info.st_mode & 0o7777, radix: 8) + (attributes.isEmpty ? "" : " xattr:" + attributes)
                }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    out[rel] = "folder mtime:\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)" + (try metadata())
                    try walk(url, rel)
                case S_IFLNK:
                    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { throw unreadable(rel) }
                    // A link's own attributes, read without following it: restic keeps those too. Its own
                    // modification time it does not give back on macOS (restic 0.19), so that is not compared.
                    guard let attributes = Self.attributesDigest(url.path) else { throw unreadable(rel) }
                    // The target is length-prefixed: it may itself read like the metadata that follows it.
                    out[rel] = "link \(target.utf8.count):" + target + (attributes.isEmpty ? "" : " xattr:" + attributes)
                    read.append((url, rel, false, state(of: info)))
                case S_IFREG:
                    guard let sha = DocumentPaths.sha256(of: url) else { throw unreadable(rel) }
                    afterRead(url)
                    // The digest counts only for the file that was there before and after it was read: an editor's
                    // save (a new file renamed into place, or a write) during the read fails the manifest.
                    var after = stat()
                    guard lstat(url.path, &after) == 0, after.st_dev == info.st_dev, after.st_ino == info.st_ino,
                          after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                          after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                          after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                          after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
                        throw Failure(message: "\(rel) changed while it was read; nothing was removed")
                    }
                    if let checked = state(url, follow: false) { read.append((url, rel, false, checked)) }
                    let mtime = " mtime:\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
                    var link = ""
                    if info.st_nlink > 1 {
                        let inode = "\(info.st_dev):\(info.st_ino)"
                        if let first = linked[inode] { link = " hardlink:" + first } else { linked[inode] = rel }
                    }
                    out[rel] = sha + mtime + (try metadata()) + link
                case S_IFSOCK:
                    continue
                default:
                    // A FIFO or device node: restic keeps its permission bits and the device it stands for.
                    guard let attributes = Self.attributesDigest(url.path) else { throw unreadable(rel) }
                    out[rel] = "special \(info.st_mode & S_IFMT) mode:" + String(info.st_mode & 0o7777, radix: 8) + " rdev:\(info.st_rdev)"
                        + (attributes.isEmpty ? "" : " xattr:" + attributes)
                    read.append((url, rel, false, state(of: info)))
                }
            }
        }
        try walk(folder, "")
        // In reverse order, so each folder is checked after everything under it: a save into a folder while later
        // entries are checked is still seen.
        for entry in read.reversed() where state(entry.url, follow: entry.follow) != entry.state {
            throw Failure(message: "\(entry.rel.isEmpty ? "the binder" : entry.rel) changed while it was read; nothing was removed")
        }
        return out
    }

    /// Extended attributes macOS sets and keeps itself, which a restore cannot write back: the process that wrote a
    /// file (`com.apple.provenance`), sandbox access grants (`com.apple.macl`, protected), System Integrity
    /// Protection's mark, and the last-opened date Finder updates on every open. Everything else counts.
    static let volatileAttributes: Set<String> = ["com.apple.provenance", "com.apple.macl", "com.apple.rootless", "com.apple.lastuseddate#PS"]

    /// A digest of an entry's extended attributes, names and values, without following a link; "" when it has none
    /// that count, nil when they cannot be read.
    static func attributesDigest(_ path: String) -> String? {
        guard let values = attributes(path) else { return nil }
        if values.isEmpty { return "" }
        var hasher = SHA256()
        for name in values.keys.sorted() {
            let value = values[name] ?? Data()
            hasher.update(data: Data(name.utf8) + [0] + withUnsafeBytes(of: UInt64(value.count).bigEndian) { Data($0) } + value)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// An entry's extended attributes that count (all but `volatileAttributes`), by name, without following a link;
    /// nil when they cannot be read.
    static func attributes(_ path: String) -> [String: Data]? {
        func list() -> [String]? {
            for _ in 0..<3 {
                let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { return nil }
                if size == 0 { return [] }
                var buffer = [CChar](repeating: 0, count: size)
                let got = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
                if got < 0 { if errno == ERANGE { continue }; return nil }
                return buffer.prefix(got).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            }
            return nil
        }
        guard let names = list()?.filter({ !volatileAttributes.contains($0) }) else { return nil }
        var out: [String: Data] = [:]
        for name in names {
            var value: [UInt8]?
            for _ in 0..<3 {
                let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { if errno == ENOATTR { value = []; break }; return nil }
                var buffer = [UInt8](repeating: 0, count: size)
                let got = getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW)
                if got < 0 { if errno == ERANGE { continue }; if errno == ENOATTR { value = []; break }; return nil }
                value = Array(buffer.prefix(got))
                break
            }
            guard let value else { return nil }
            out[name] = Data(value)
        }
        return out
    }


    // MARK: - The binder folder's own metadata
    static func rootMetadata(_ folder: URL) throws -> RootMetadata {
        // The binder folder itself, also when it is reached through a link (as `BinderSprava` opens it).
        let path = folder.resolvingSymlinksInPath().path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, let values = attributes(path) else {
            throw Failure(message: "the binder folder's own settings cannot be read; nothing was removed")
        }
        return RootMetadata(mode: Int(info.st_mode & 0o7777), attributes: values)
    }

    /// Where a binder keeps its own folder's metadata, so every snapshot holds it beside the entries (restic takes
    /// the folder's entries, not the folder): a restore reads it back from the snapshot itself, and needs no record.
    static let folderMetadataPath = ".sprava/folder-metadata.json"

    /// The folder's own metadata, written into `folderMetadataPath` when it differs from what is there, before a
    /// snapshot is taken. A `.sprava` that is not a real folder is refused (never written through a link).
    @discardableResult
    static func keepRootMetadata(_ folder: URL) throws -> RootMetadata {
        let metadata = try rootMetadata(folder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        guard let sprava = try? BinderSprava.open(folder, create: false) else {
            throw Failure(message: "the binder's .sprava folder is missing or not a folder; nothing was backed up")
        }
        let name = URL(fileURLWithPath: folderMetadataPath).lastPathComponent
        let kept: Data? = if case .ok(let read) = sprava.read(name, limit: 1024 * 1024) { read } else { nil }
        if kept != data { try sprava.write(data, to: name) }
        // What was kept counts only if the folder still has it: a tag or permission change meanwhile would otherwise
        // leave the snapshot with the old one.
        guard try rootMetadata(folder) == metadata else {
            throw Failure(message: "the binder folder's own settings changed while they were kept; nothing was backed up")
        }
        return metadata
    }

    /// One digest for a whole manifest, to tell later whether the binder still matches it. Every field is
    /// length-prefixed: names and link targets may hold tabs and newlines, and two different manifests must never
    /// read as the same bytes.
    static func digest(_ manifest: [String: String]) -> String {
        var hasher = SHA256()
        func field(_ text: String) {
            let bytes = Data(text.utf8)
            hasher.update(data: withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { Data($0) } + bytes)
        }
        for name in manifest.keys.sorted() {
            field(name)
            field(manifest[name] ?? "")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
