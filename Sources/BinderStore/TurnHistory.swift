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
/// entry, and refuses, changing nothing, when any of its paths has changed since, or when the catalog changed while the
/// turn ran or now files what the turn made. Very large files are tracked as key files are. Key files (`DocumentPaths.isKeyFile`) are
/// tracked by name only and never copied here, so deleting a secret really deletes it, and Undo says it cannot return.
///
/// One caller at a time per binder: the runtime holds the binder's turn slot around every call.
public struct TurnHistory: Sendable {
    public enum Refused: Error, Equatable { case tooManyFiles, tooMuchData, unreadable(String), unknownEntry, damaged, cancelled }

    struct Item: Codable, Equatable {
        /// `key` and `large` are tracked by name, size and time only: their bytes are never kept.
        enum Kind: String, Codable { case file, link, key, large }
        var kind: Kind
        var sha256: String?
        var target: String?
        var size: Int64
        var modified: Int64
        /// Moves when extended attributes do, which the modification time does not.
        var changed: Int64 = 0
        var inode: UInt64
        var mode: UInt16

        /// Whether two items hold the same thing; a touched file with the same bytes is not a change.
        func sameContent(as other: Item) -> Bool {
            guard kind == other.kind else { return false }
            switch kind {
            case .file: return sha256 == other.sha256
            case .link: return target == other.target
            case .key, .large: return size == other.size && modified == other.modified
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
        /// The catalog changed between the records around this entry: something was filed or approved while it ran.
        var recordsChanged = false

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

        /// Key files and very large ones this entry changed or deleted: their earlier bytes were never kept.
        public var notRestorable: [String] { changes.filter { $0.before?.kind == .key || $0.before?.kind == .large }.map(\.path) }
    }

    public enum UndoResult: Equatable, Sendable {
        case undone
        /// Nothing was changed: these paths are no longer as the turn left them.
        case conflict([String])
        /// Nothing was changed: the catalog moved during the turn, or now files one of its results, and reverting files alone
        /// would leave it pointing at documents that are gone. Those changes have their own Undo under Recent changes.
        case recordsChanged
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
    /// Above this a file is tracked by name only. A sparse file can claim terabytes on a healthy volume.
    static let maximumFileBytes: Int64 = 1 << 30
    /// New bytes one record may copy and hash; past it the record is refused, and the turn runs with no tools.
    static let maximumRecordBytes: Int64 = 20 << 30
    static let maximumCatalogBytes = 64 << 20
    /// Above this, in all, a file's attributes put it with the very large files: a resource fork can be any size.
    static let maximumAttributeBytes = 64 << 20
    let root: URL
    var blobs: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    var entries: URL { root.appendingPathComponent("entries", isDirectory: true) }
    var head: URL { root.appendingPathComponent("head.json") }
    var catalogStamp: URL { root.appendingPathComponent("catalog-stamp") }

    /// Production: `binder-store/history/<binder id>` in the support folder.
    public init(support: URL, binder: UUID) {
        root = support.appendingPathComponent("binder-store/history/\(binder.uuidString)", isDirectory: true)
    }

    /// Records what differs from the last record. The first call stores the baseline and returns nil, as does a call that
    /// finds nothing changed.
    @discardableResult
    public func record(_ folder: URL, turn: UUID? = nil, now: Date = Date(), cancelled: @Sendable () -> Bool = { false }) throws -> Entry? {
        try AtomicFile.makePrivateFolder(root); try AtomicFile.makePrivateFolder(blobs); try AtomicFile.makePrivateFolder(entries)
        let known = try readHead()
        let current = try scan(folder, known: known ?? [:], cancelled: cancelled)
        let stamp = try Self.stamp(folder), recordsChanged = (try? Data(contentsOf: catalogStamp)) != stamp
        try writeHead(current)
        try AtomicFile.write(stamp, to: catalogStamp)
        guard let known else { return nil }
        var changes: [Change] = []
        for path in Set(known.keys).union(current.keys).sorted() where known[path].flatMap({ old in current[path].map { old.sameContent(as: $0) } }) != true {
            changes.append(Change(path: path, before: known[path], after: current[path]))
        }
        defer { try? prune(now: now) }
        guard !changes.isEmpty else { return nil }
        let entry = Entry(id: UUID(), turn: turn, at: now, changes: changes, undone: false, recordsChanged: recordsChanged)
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
        guard !entry.recordsChanged, Self.keepsCatalogTrue(entry, in: folder) else { return .recordsChanged }
        if let occupied = try apply(entry, in: folder) { return .conflict([occupied]) }
        entry.undone = true
        try write(entry)
        try record(folder, now: now)
        return .undone
    }

    /// Whether reverting leaves every filed document where the catalog says: a file this turn made may have been filed since.
    private static func keepsCatalogTrue(_ entry: Entry, in folder: URL) -> Bool {
        guard let bytes = safeCatalog(folder) else { return false }
        guard !bytes.isEmpty else { return true }
        guard let text = String(data: bytes, encoding: .utf8), let parsed = try? JSONParser.parse(text), parsed.safety.isSafe else { return false }
        // Folded, as the writer compares them: on most volumes Report.txt and report.txt are one file.
        let filed = Set((parsed.value["documents"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }.map(DocumentPaths.fold))
        return !entry.changes.contains { $0.before == nil && filed.contains(DocumentPaths.fold($0.path)) }
    }

    /// The catalog's bytes, empty when there is none, nil when what is there cannot be read as an ordinary bounded file: a
    /// pipe there must not hang a conversation, nor a link or a huge file stand in for it.
    private static func safeCatalog(_ folder: URL) -> Data? {
        switch SafeFile.read(folder.appendingPathComponent("catalog.json"), limit: maximumCatalogBytes) {
        case .ok(let bytes): return bytes
        case .missing: return Data()
        default: return nil
        }
    }

    /// Whether Undo leaves this change as it is: mail and files arrive in intake on their own, during a turn too, so it must
    /// not delete what it never saw made; and a key file's earlier bytes were never kept.
    private static func left(_ change: Change) -> Bool {
        if change.before == nil { return change.path.hasPrefix("intake/") }
        return change.before?.kind == .key || change.before?.kind == .large
    }

    /// Stages every restored file first, then moves the current ones aside, then moves the staged ones in. All of it is
    /// renames inside the binder, so any failure moves everything back. Moving aside comes first because on a
    /// case-insensitive volume `Report.txt` and `report.txt` are one file. Returns a path that stopped it, if one did.
    private func apply(_ entry: Entry, in folder: URL) throws -> String? {
        let manager = FileManager.default
        let work = folder.appendingPathComponent(".sprava-undo-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let changes = entry.changes.filter { !Self.left($0) }
        var staged: [(URL, URL)] = []
        for (index, change) in changes.enumerated() {
            guard let before = change.before else { continue }
            let file = work.appendingPathComponent("new-\(index)")
            if before.kind == .link, let target = before.target {
                try manager.createSymbolicLink(atPath: file.path, withDestinationPath: target)
            } else if let sha = before.sha256 {
                guard manager.fileExists(atPath: blob(sha).path) else { throw Refused.damaged }
                try manager.copyItem(at: blob(sha), to: file)
                guard chmod(file.path, mode_t(before.mode)) == 0 else { throw Refused.unreadable(change.path) }
            } else { throw Refused.damaged }
            staged.append((file, folder.appendingPathComponent(change.path)))
        }
        var aside: [(URL, URL)] = [], placed: [(URL, URL)] = []
        func undoMoves() {
            for (from, to) in placed.reversed() { _ = rename(to.path, from.path) }
            for (from, to) in aside.reversed() { _ = rename(to.path, from.path) }
        }
        for (index, change) in changes.enumerated() where change.after != nil {
            let from = folder.appendingPathComponent(change.path), to = work.appendingPathComponent("old-\(index)")
            guard rename(from.path, to.path) == 0 else { undoMoves(); return change.path }
            aside.append((from, to))
        }
        for (from, to) in staged {
            let path = String(to.path.dropFirst(folder.path.count + 1))
            var info = stat()
            // A folder or a new file now sits where this one goes: never overwrite it.
            guard lstat(to.path, &info) != 0, errno == ENOENT,
                  (try? manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
                  rename(from.path, to.path) == 0 else { undoMoves(); return path }
            placed.append((from, to))
        }
        // Folders the turn's files leave empty go too, never the binder itself.
        for change in changes where change.before == nil {
            var parent = folder.appendingPathComponent(change.path).deletingLastPathComponent()
            while parent.path.count > folder.path.count, rmdir(parent.path) == 0 { parent.deleteLastPathComponent() }
        }
        return nil
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

    private func scan(_ folder: URL, known: [String: Item], cancelled: @Sendable () -> Bool) throws -> [String: Item] {
        var found: [String: Item] = [:], budget = Self.maximumRecordBytes
        func walk(_ directory: URL, _ prefix: String) throws {
            guard !cancelled() else { throw Refused.cancelled }
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
                    found[path] = try item(url, path: path, info: info, known: known[path], budget: &budget, cancelled: cancelled)
                default: continue // A pipe or socket holds nothing to keep, and reading one could hang.
                }
            }
        }
        try walk(folder, "")
        return found
    }

    private func item(_ url: URL, path: String, info: stat, known: Item?, budget: inout Int64, cancelled: @Sendable () -> Bool) throws -> Item {
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        let changed = Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
        var item = Item(kind: .file, size: Int64(info.st_size), modified: modified, changed: changed, inode: UInt64(info.st_ino), mode: UInt16(info.st_mode & 0o777))
        if info.st_mode & S_IFMT == S_IFLNK {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { throw Refused.unreadable(path) }
            item.kind = .link; item.target = target
            return item
        }
        if DocumentPaths.isKeyFile(path) { item.kind = .key; return item }
        if item.size > Self.maximumFileBytes || Self.attributeBytes(of: url) > Self.maximumAttributeBytes { item.kind = .large; return item }
        // Same size, time and inode: the bytes were kept when this file was last read.
        if let known, known.kind == .file, known.size == item.size, known.modified == modified, known.changed == changed, known.inode == item.inode,
           let sha = known.sha256, FileManager.default.fileExists(atPath: blob(sha).path) {
            item.sha256 = sha
            return item
        }
        budget -= item.size
        guard budget >= 0 else { throw Refused.tooMuchData }
        item.sha256 = try keep(url, path: path, cancelled: cancelled)
        return item
    }

    /// Clones the file, then hashes the clone, so a blob's name is always the hash of what it holds.
    private func keep(_ url: URL, path: String, cancelled: @Sendable () -> Bool) throws -> String {
        let manager = FileManager.default
        let staged = blobs.appendingPathComponent("staged-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staged) }
        do { try manager.copyItem(at: url, to: staged) } catch { throw Refused.unreadable(path) }
        guard chmod(staged.path, 0o600) == 0, let handle = try? FileHandle(forReadingFrom: staged) else { throw Refused.unreadable(path) }
        defer { try? handle.close() }
        var data = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            guard !cancelled() else { throw Refused.cancelled }
            data.update(data: chunk)
        }
        // The bytes' hash and each attribute's lengths come first, so no file and attributes can read as another's.
        var hash = SHA256()
        hash.update(data: Data(data.finalize()))
        Self.hashAttributes(of: staged, into: &hash)
        let sha = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let target = blob(sha)
        try AtomicFile.makePrivateFolder(target.deletingLastPathComponent())
        if !manager.fileExists(atPath: target.path) { try manager.moveItem(at: staged, to: target) }
        return sha
    }

    /// A file's identity includes what is kept in its extended attributes: Skim's annotations live there, as do resource
    /// forks, Finder tags and comments, and the clone keeps them. Only attributes known to be macOS's own bookkeeping are left
    /// out, so that opening or downloading a file is not a change.
    static func countsAsContent(_ attribute: String) -> Bool {
        !["com.apple.lastuseddate#PS", "com.apple.quarantine", "com.apple.provenance", "com.apple.macl",
          "com.apple.metadata:kMDItemDownloadedDate", "com.apple.metadata:kMDItemWhereFroms"].contains(attribute)
    }

    private static func attributeNames(of url: URL) -> [String] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &names, size, XATTR_NOFOLLOW) == size else { return [] }
        return names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.filter(countsAsContent).sorted()
    }

    private static func attributeBytes(of url: URL) -> Int {
        attributeNames(of: url).reduce(0) { $0 + max(0, getxattr(url.path, $1, nil, 0, 0, XATTR_NOFOLLOW)) }
    }

    private static func hashAttributes(of url: URL, into hash: inout SHA256) {
        func add(_ bytes: Data) { hash.update(data: withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { Data($0) }); hash.update(data: bytes) }
        for name in attributeNames(of: url) {
            let length = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0, length <= maximumAttributeBytes else { continue }
            var value = [UInt8](repeating: 0, count: length)
            guard getxattr(url.path, name, &value, length, 0, XATTR_NOFOLLOW) == length else { continue }
            add(Data(name.utf8)); add(Data(value))
        }
    }

    /// The catalog's bytes, by hash: enough to tell whether something was filed or approved between two records.
    private static func stamp(_ folder: URL) throws -> Data {
        guard let bytes = safeCatalog(folder) else { throw Refused.unreadable("catalog.json") }
        return Data(SHA256.hash(data: bytes))
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
