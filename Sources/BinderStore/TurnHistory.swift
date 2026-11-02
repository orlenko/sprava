import BinderFormat
import CryptoKit
import Darwin
import Foundation
import SpravaKit

/// A binder's version history, kept outside its folder (conversation.md 18.4). The binder stays a plain folder: copied
/// projects with their own `.git`, large PDFs and links are all just files here, and a file's bytes are stored once,
/// by hash, as an APFS clone where the volume allows it.
///
/// Sprava records what changed before a turn (the person's own edits) and after it (the turn's). Undo reverts one turn's
/// entry, and refuses, changing nothing, when any of its paths has changed since. Key files (`DocumentPaths.isKeyFile`) are
/// tracked by name only and never copied here, so deleting a secret really deletes it, and Undo says it cannot return.
///
/// One caller at a time per binder: the runtime holds the binder's turn slot around every call.
public struct TurnHistory: Sendable {
    public enum Refused: Error, Equatable { case tooManyFiles, unreadable(String), unknownEntry, damaged }

    struct Item: Codable, Equatable {
        enum Kind: String, Codable { case file, link, key }
        var kind: Kind
        var sha256: String?
        var target: String?
        var size: Int64
        var modified: Int64
        var inode: UInt64
        var mode: UInt16

        /// Whether two items hold the same thing; a touched file with the same bytes is not a change.
        func sameContent(as other: Item) -> Bool {
            guard kind == other.kind else { return false }
            switch kind {
            case .file: return sha256 == other.sha256
            case .link: return target == other.target
            case .key: return size == other.size && modified == other.modified
            }
        }
    }

    struct Change: Codable, Equatable {
        var path: String
        var before: Item?
        var after: Item?
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let id: UUID
        public let turn: UUID?
        public let at: Date
        var changes: [Change]
        public internal(set) var undone: Bool

        /// One line for the conversation: counts, up to three paths, and any file Undo cannot bring back.
        public var summary: String {
            let added = changes.filter { $0.before == nil }.count, removed = changes.filter { $0.after == nil }.count
            let changed = changes.count - added - removed
            let counts = [(added, "added"), (changed, "changed"), (removed, "deleted")].filter { $0.0 > 0 }
                .map { "\($0.1) \($0.0) file\($0.0 == 1 ? "" : "s")" }.joined(separator: ", ")
            let names = changes.prefix(3).map(\.path).joined(separator: ", ") + (changes.count > 3 ? ", …" : "")
            let line = counts.prefix(1).uppercased() + counts.dropFirst() + ": " + names
            return notRestorable.isEmpty ? line
                : line + ". Not kept, so Undo cannot bring back: " + notRestorable.prefix(3).joined(separator: ", ")
        }

        /// Key files this entry changed or deleted: their earlier bytes were never kept.
        public var notRestorable: [String] { changes.filter { $0.before?.kind == .key }.map(\.path) }
    }

    public enum UndoResult: Equatable, Sendable {
        case undone
        /// Nothing was changed: these paths are no longer as the turn left them.
        case conflict([String])
    }

    /// The folder's own state and the files one writer owns are not the conversation's to version; `.sprava` holds the
    /// op log, whose Undo already covers them. `.DS_Store` is noise that Finder rewrites.
    static func excluded(_ path: String) -> Bool {
        let first = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
        if first == ".sprava" || path == "catalog.json" || path == "DASHBOARD.md" { return true }
        return (path as NSString).lastPathComponent == ".DS_Store"
    }

    public static let keepDays = 30
    static let maximumFiles = 200_000
    let root: URL
    var blobs: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    var entries: URL { root.appendingPathComponent("entries", isDirectory: true) }
    var head: URL { root.appendingPathComponent("head.json") }

    /// Production: `binder-store/history/<binder id>` in the support folder.
    public init(support: URL, binder: UUID) {
        root = support.appendingPathComponent("binder-store/history/\(binder.uuidString)", isDirectory: true)
    }

    /// Records what differs from the last record. The first call stores the baseline and returns nil, as does a call that
    /// finds nothing changed.
    @discardableResult
    public func record(_ folder: URL, turn: UUID? = nil, now: Date = Date()) throws -> Entry? {
        try AtomicFile.makePrivateFolder(root); try AtomicFile.makePrivateFolder(blobs); try AtomicFile.makePrivateFolder(entries)
        let known = try readHead()
        let current = try scan(folder, known: known ?? [:])
        try writeHead(current)
        guard let known else { return nil }
        var changes: [Change] = []
        for path in Set(known.keys).union(current.keys).sorted() where known[path].flatMap({ old in current[path].map { old.sameContent(as: $0) } }) != true {
            changes.append(Change(path: path, before: known[path], after: current[path]))
        }
        defer { try? prune(now: now) }
        guard !changes.isEmpty else { return nil }
        let entry = Entry(id: UUID(), turn: turn, at: now, changes: changes, undone: false)
        try write(entry)
        return entry
    }

    /// The entry a turn left, or nil when it changed nothing.
    public func entry(forTurn turn: UUID) throws -> Entry? {
        let url = entries.appendingPathComponent("turn-\(turn.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else { throw Refused.damaged }
        return entry
    }

    /// Reverts one turn's entry, whole or not at all.
    public func undo(turn: UUID, in folder: URL, now: Date = Date()) throws -> UndoResult {
        guard var entry = try entry(forTurn: turn) else { throw Refused.unknownEntry }
        guard !entry.undone else { return .undone }
        try record(folder, now: now) // The person's edits since, so a later change shows as one.
        let current = try readHead() ?? [:]
        var conflicts: [String] = []
        for change in entry.changes {
            let now = current[change.path]
            let unchanged = switch (now, change.after) {
            case (nil, nil): true
            case let (a?, b?): a.sameContent(as: b)
            default: false
            }
            if !unchanged || !Self.safeToWrite(change.path, in: folder) { conflicts.append(change.path) }
        }
        guard conflicts.isEmpty else { return .conflict(conflicts) }
        // Bytes first: a missing blob must refuse the whole Undo before anything moved.
        for change in entry.changes where change.before?.kind == .file {
            guard let sha = change.before?.sha256, FileManager.default.fileExists(atPath: blob(sha).path) else { throw Refused.damaged }
        }
        for change in entry.changes { try restore(change, in: folder) }
        entry.undone = true
        try write(entry)
        try record(folder, now: now)
        return .undone
    }

    /// Whether every folder above the path is a real folder or absent: a link swapped in by a later turn must not carry a
    /// restored file out of the binder.
    static func safeToWrite(_ path: String, in folder: URL) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".") else { return false }
        var at = folder
        for part in parts.dropLast() {
            at.appendPathComponent(part)
            var info = stat()
            if lstat(at.path, &info) != 0 { return errno == ENOENT }
            if info.st_mode & S_IFMT != S_IFDIR { return false }
        }
        return true
    }

    private func restore(_ change: Change, in folder: URL) throws {
        let url = folder.appendingPathComponent(change.path)
        let manager = FileManager.default
        guard let before = change.before else {
            // Mail and files arrive in intake on their own, during a turn too; Undo must not delete what it never saw made.
            if change.path.hasPrefix("intake/") { return }
            try manager.removeItem(at: url)
            // Folders the turn's files leave empty go too, never the binder itself.
            var parent = url.deletingLastPathComponent()
            while parent.path.count > folder.path.count, rmdir(parent.path) == 0 { parent.deleteLastPathComponent() }
            return
        }
        guard before.kind != .key else { return } // Its bytes were never kept; the entry's summary says so.
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = url.deletingLastPathComponent().appendingPathComponent(".sprava-undo-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staged) }
        if before.kind == .link, let target = before.target {
            try manager.createSymbolicLink(atPath: staged.path, withDestinationPath: target)
        } else if let sha = before.sha256 {
            try manager.copyItem(at: blob(sha), to: staged)
            guard chmod(staged.path, mode_t(before.mode)) == 0 else { throw Refused.unreadable(change.path) }
        }
        guard rename(staged.path, url.path) == 0 else { throw Refused.unreadable(change.path) }
    }

    private func scan(_ folder: URL, known: [String: Item]) throws -> [String: Item] {
        var found: [String: Item] = [:]
        func walk(_ directory: URL, _ prefix: String) throws {
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
            catch { throw Refused.unreadable(prefix) }
            for name in names {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if Self.excluded(path) || name.hasPrefix(".sprava-undo-") { continue }
                let url = directory.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw Refused.unreadable(path) }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: try walk(url, path)
                case S_IFREG, S_IFLNK:
                    guard found.count < Self.maximumFiles else { throw Refused.tooManyFiles }
                    found[path] = try item(url, path: path, info: info, known: known[path])
                default: continue // A pipe or socket holds nothing to keep, and reading one could hang.
                }
            }
        }
        try walk(folder, "")
        return found
    }

    private func item(_ url: URL, path: String, info: stat, known: Item?) throws -> Item {
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        var item = Item(kind: .file, size: Int64(info.st_size), modified: modified, inode: UInt64(info.st_ino), mode: UInt16(info.st_mode & 0o777))
        if info.st_mode & S_IFMT == S_IFLNK {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { throw Refused.unreadable(path) }
            item.kind = .link; item.target = target
            return item
        }
        if DocumentPaths.isKeyFile(path) { item.kind = .key; return item }
        // Same size, time and inode: the bytes were kept when this file was last read.
        if let known, known.kind == .file, known.size == item.size, known.modified == modified, known.inode == item.inode,
           let sha = known.sha256, FileManager.default.fileExists(atPath: blob(sha).path) {
            item.sha256 = sha
            return item
        }
        item.sha256 = try keep(url, path: path)
        return item
    }

    /// Clones the file, then hashes the clone, so a blob's name is always the hash of what it holds.
    private func keep(_ url: URL, path: String) throws -> String {
        let manager = FileManager.default
        let staged = blobs.appendingPathComponent("staged-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staged) }
        do { try manager.copyItem(at: url, to: staged) } catch { throw Refused.unreadable(path) }
        guard chmod(staged.path, 0o600) == 0, let handle = try? FileHandle(forReadingFrom: staged) else { throw Refused.unreadable(path) }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        let sha = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let target = blob(sha)
        try AtomicFile.makePrivateFolder(target.deletingLastPathComponent())
        if !manager.fileExists(atPath: target.path) { try manager.moveItem(at: staged, to: target) }
        return sha
    }

    private func blob(_ sha: String) -> URL { blobs.appendingPathComponent(String(sha.prefix(2))).appendingPathComponent(sha) }

    private func readHead() throws -> [String: Item]? {
        guard let data = try? Data(contentsOf: head) else { return nil }
        guard let value = try? JSONDecoder().decode([String: Item].self, from: data) else { throw Refused.damaged }
        return value
    }
    private func writeHead(_ value: [String: Item]) throws { try AtomicFile.write(try JSONEncoder().encode(value), to: head) }

    private func write(_ entry: Entry) throws {
        let name = entry.turn.map { "turn-\($0.uuidString).json" } ?? "edit-\(entry.id.uuidString).json"
        try AtomicFile.write(try JSONEncoder().encode(entry), to: entries.appendingPathComponent(name))
    }

    /// Forgets entries past the keeping time, and the bytes nothing refers to any more.
    func prune(now: Date) throws {
        let manager = FileManager.default
        var kept = Set<String>()
        for item in try readHead()?.values ?? [:].values { if let sha = item.sha256 { kept.insert(sha) } }
        for name in try manager.contentsOfDirectory(atPath: entries.path) {
            let url = entries.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
            if now.timeIntervalSince(entry.at) > TimeInterval(Self.keepDays * 86_400) { try manager.removeItem(at: url); continue }
            for change in entry.changes {
                if let sha = change.before?.sha256 { kept.insert(sha) }
                if let sha = change.after?.sha256 { kept.insert(sha) }
            }
        }
        for shard in try manager.contentsOfDirectory(atPath: blobs.path) where shard.count == 2 {
            let folder = blobs.appendingPathComponent(shard)
            for name in try manager.contentsOfDirectory(atPath: folder.path) where !kept.contains(name) {
                try manager.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    /// Removes this binder's history, its copies of the binder's files with it.
    public func forget() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}
