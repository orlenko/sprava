import Darwin
import Foundation

/// Where Sprava keeps its own state: `$SPRAVA_SUPPORT_DIR`, else `~/Library/Application Support/Sprava`.
/// Nothing Sprava keeps about a binder before adoption lives inside the binder (mvp.md feature 1).
public enum SpravaPaths {
    public static func supportDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let env = environment["SPRAVA_SUPPORT_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sprava", isDirectory: true)
    }
}

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

    func contents() -> Contents? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: data)
    }

    /// Whether the Shelf lists lifeproj's registry (`"showRegistry": true` in shelf.json).
    public var showsRegistry: Bool { contents()?.showRegistry == true }

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

    public struct Unreadable: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "\(path) exists but cannot be read; it was left as it is" }
    }

    /// The picked folders. A missing file is an empty shelf; a file that exists but cannot be read or decoded
    /// throws, so nothing ever saves over it (Sprava's own state, never a binder's).
    public func readFolders() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let data = try? Data(contentsOf: file),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else { throw Unreadable(path: file.path) }
        return contents.folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The picked folders, or none when the file cannot be read (callers that write use `readFolders`).
    public func pickedFolders() -> [URL] { (try? readFolders()) ?? [] }

    public func add(_ folder: URL) throws {
        try locked {
            var folders = try readFolders().map(\.path)
            let path = folder.standardizedFileURL.path
            guard !folders.contains(where: { Shelf.identity($0) == Shelf.identity(path) }) else { return }
            folders.append(path)
            try save(folders)
        }
    }

    public func remove(_ folder: URL) throws {
        let path = folder.standardizedFileURL.path
        try locked { try save(try readFolders().map(\.path).filter { Shelf.identity($0) != Shelf.identity(path) }) }
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

    private func save(_ folders: [String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var c = contents() ?? Contents()
        c.folders = folders
        try encoder.encode(c).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// One row of the Shelf (mvp.md feature 1).
public struct ShelfRow: Sendable {
    public enum Source: String, Sendable { case registry, picked }

    public let folder: URL
    public let source: Source
    public let archived: Bool
    public let teka: Teka

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

    public func opened() -> [String: Date] {
        guard let data = try? Data(contentsOf: file), case .object(let o)? = try? JSONParser.parse(data).value else { return [:] }
        var out: [String: Date] = [:]
        for e in o.entries { if let d = e.value.stringValue.flatMap(ISOTime.date) { out[e.key] = d } }
        return out
    }

    public func touch(_ folder: URL, now: Date = Date()) {
        var all = opened()
        all[folder.standardizedFileURL.path] = now
        let o = JSONObject(all.sorted { $0.key < $1.key }.map { (key: $0.key, value: JSONValue.string(ISOTime.string($0.value))) })
        try? AtomicFile.makePrivateFolder(file.deletingLastPathComponent())
        try? AtomicFile.write(Data(JSONWriter.pretty(.object(o)).utf8), to: file)
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
