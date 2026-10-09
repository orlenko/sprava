import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// The folders the person picked by hand, kept in Sprava's own state as `shelf.json`.
public struct ShelfStore: Sendable {
    public let file: URL

    public init(supportDirectory: URL = SpravaPaths.supportDirectory()) {
        file = supportDirectory.appendingPathComponent("shelf.json")
    }

    struct Contents: Codable {
        var schemaVersion = 1
        var folders: [String] = []
        /// Whether lifeproj's registry is on the Shelf. Off unless set: older binders come in one at a time,
        /// with Add Folder (author's call, 2026-10-08).
        var showRegistry: Bool?
    }

    /// Whether the Shelf lists lifeproj's registry (`"showRegistry": true` in shelf.json).
    public var showsRegistry: Bool { (try? readContents())?.showRegistry == true }

    /// lifeproj's registry when the Shelf shows it, else nil. Throws only when it is shown and unreadable.
    public func registryForShelf() throws -> LifeprojRegistry? {
        guard showsRegistry else { return nil }
        let url = LifeprojRegistry.defaultPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try LifeprojRegistry.load(from: url)
    }

    /// The Shelf: picked folders, plus lifeproj's registry when it is shown.
    public func rows(includeArchived: Bool = false) -> [ShelfRow] {
        Shelf.rows(registry: try? registryForShelf(), picked: pickedFolders(), includeArchived: includeArchived)
    }

    /// The error of every state file that exists but cannot be read (SpravaKit's `StateFile`).
    public typealias Unreadable = StateFile.Unreadable

    /// The picked folders. A missing file is an empty shelf; a file that exists but cannot be read or decoded
    /// throws, so nothing ever saves over it (Sprava's own state, never a binder's).
    public func readFolders() throws -> [URL] {
        try readContents().folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// shelf.json through `StateFile`: a link to state out of reach is unreadable, never absent.
    func readContents() throws -> Contents { try StateFile.read(Contents.self, from: file) ?? Contents() }

    /// The picked folders, or none when the file cannot be read (callers that write use `readFolders`).
    public func pickedFolders() -> [URL] { (try? readFolders()) ?? [] }

    /// The contents a writer may change. A shelf.json from a newer Sprava may hold fields this one does not know and
    /// would drop on saving, so it throws and is left as it is.
    func writableContents() throws -> Contents {
        let c = try readContents()
        guard c.schemaVersion <= Contents().schemaVersion else { throw Unreadable(path: file.path) }
        return c
    }

    public func add(_ folder: URL) throws {
        try locked {
            var c = try writableContents()
            let path = folder.standardizedFileURL.path
            guard !c.folders.contains(where: { Shelf.identity($0) == Shelf.identity(path) }) else { return }
            c.folders.append(path)
            try save(c)
        }
    }

    public func remove(_ folder: URL) throws {
        let path = folder.standardizedFileURL.path
        try locked {
            var c = try writableContents()
            c.folders.removeAll { Shelf.identity($0) == Shelf.identity(path) }
            try save(c)
        }
    }

    /// The app and the runtime both change the Shelf: each read-modify-write holds a file lock next to shelf.json,
    /// so neither loses a binder the other just added.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = file.deletingLastPathComponent().appendingPathComponent("shelf.lock").path
        let fd = open(lock, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Unreadable(path: lock) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Unreadable(path: lock) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Writes the contents read under the same lock, the registry setting among them: flushed to disk with the
    /// folder before it returns, private to this user (`AtomicFile`).
    private func save(_ c: Contents) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(c), to: file)
    }
}

/// One row of the Shelf (mvp.md feature 1).
public struct ShelfRow: Sendable {
    public enum Source: String, Sendable { case registry, picked }

    public let folder: URL
    public let source: Source
    public let archived: Bool
    public let teka: Teka

    package init(folder: URL, source: Source, archived: Bool, teka: Teka) {
        self.folder = folder
        self.source = source
        self.archived = archived
        self.teka = teka
    }

    public var name: String { teka.name }

    /// The Shelf's state word: "not yet adopted" until a full implementation adopts the binder.
    public var stateLabel: String {
        switch teka.state {
        case .notATeka, .corrupt, .unknownLevel, .needsAttention: teka.state.label
        default: teka.isAdopted ? teka.state.label : "not yet adopted"
        }
    }
}

public enum Shelf {
    /// What makes two paths one folder: the path with its symbolic links resolved. Rows keep the spelling they
    /// were given, since Sprava's own state is keyed by it.
    static func identity(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Every binder the shelf knows: the registry's live entries (archived ones too, marked), then picked folders,
    /// each folder once, even when reached through a link. Reading never writes inside any binder.
    public static func rows(registry: LifeprojRegistry?, picked: [URL], includeArchived: Bool = false) -> [ShelfRow] {
        var seen = Set<String>()
        var rows: [ShelfRow] = []
        for entry in registry?.entries ?? [] where includeArchived || !entry.archived {
            guard let dir = entry.workingDir else { continue }
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            guard seen.insert(identity(url.path)).inserted else { continue }
            rows.append(ShelfRow(folder: url, source: .registry, archived: entry.archived, teka: Teka.read(url)))
        }
        for url in picked.map(\.standardizedFileURL) where seen.insert(identity(url.path)).inserted {
            rows.append(ShelfRow(folder: url, source: .picked, archived: false, teka: Teka.read(url)))
        }
        return rows
    }
}

/// When the person last opened each binder in the app, for the Shelf's order: the binder used last is on top,
/// and binders left alone sink. Sprava's own state (`recent.json`), never a binder's.
public struct RecentBinders: Sendable {
    public let file: URL

    public init(supportDirectory: URL = SpravaPaths.supportDirectory()) {
        file = supportDirectory.appendingPathComponent("recent.json")
    }

    /// When each binder was opened, for display: none when the file cannot be read (`touch` uses `readOpened`).
    public func opened() -> [String: Date] { (try? readOpened()) ?? [:] }

    /// When each binder was opened. A missing file is none; a file that exists but is not an object of dates, one
    /// entry being wrong included, throws (`StateFile.Unreadable`), so nothing ever saves over it.
    public func readOpened() throws -> [String: Date] {
        var st = stat()
        if lstat(file.path, &st) != 0 {
            if errno == ENOENT { return [:] }
            throw StateFile.Unreadable(path: file.path)
        }
        guard let data = try? Data(contentsOf: file), case .object(let o)? = try? JSONParser.parse(data).value else {
            throw StateFile.Unreadable(path: file.path)
        }
        var out: [String: Date] = [:]
        for e in o.entries {
            guard let d = e.value.stringValue.flatMap(ISOTime.date) else { throw StateFile.Unreadable(path: file.path) }
            out[e.key] = d
        }
        return out
    }

    /// Records that the person opened a binder now. Throws when recent.json cannot be read, leaving its bytes as
    /// they are, or cannot be written.
    public func touch(_ folder: URL, now: Date = Date()) throws {
        var all = try readOpened()
        all[folder.standardizedFileURL.path] = now
        let o = JSONObject(all.sorted { $0.key < $1.key }.map { (key: $0.key, value: JSONValue.string(ISOTime.string($0.value))) })
        try AtomicFile.makePrivateFolder(file.deletingLastPathComponent())
        try AtomicFile.write(Data(JSONWriter.pretty(.object(o)).utf8), to: file)
    }

    /// Opened binders first, most recent on top; then the others, most recently changed first.
    public static func order(_ rows: [ShelfRow], opened: [String: Date]) -> [ShelfRow] {
        rows.enumerated().sorted { a, b in
            let x = opened[a.element.folder.standardizedFileURL.path], y = opened[b.element.folder.standardizedFileURL.path]
            switch (x, y) {
            case let (x?, y?): return x != y ? x > y : a.offset < b.offset
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                let m = a.element.teka.modified ?? .distantPast, n = b.element.teka.modified ?? .distantPast
                return m != n ? m > n : a.offset < b.offset
            }
        }.map(\.element)
    }
}
