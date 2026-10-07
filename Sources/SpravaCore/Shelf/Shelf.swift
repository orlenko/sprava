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
    }

    public func pickedFolders() -> [URL] {
        guard let data = try? Data(contentsOf: file),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else { return [] }
        return contents.folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func add(_ folder: URL) throws {
        var folders = pickedFolders().map(\.path)
        let path = folder.standardizedFileURL.path
        guard !folders.contains(path) else { return }
        folders.append(path)
        try save(folders)
    }

    public func remove(_ folder: URL) throws {
        let path = folder.standardizedFileURL.path
        try save(pickedFolders().map(\.path).filter { $0 != path })
    }

    private func save(_ folders: [String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Contents(folders: folders)).write(to: file, options: [.atomic])
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
    /// Every binder the shelf knows: the registry's live entries (archived ones too, marked), then picked folders,
    /// each folder once. Reading never writes inside any binder.
    public static func rows(registry: LifeprojRegistry?, picked: [URL], includeArchived: Bool = false) -> [ShelfRow] {
        var seen = Set<String>()
        var rows: [ShelfRow] = []
        for entry in registry?.entries ?? [] where includeArchived || !entry.archived {
            guard let dir = entry.workingDir else { continue }
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            rows.append(ShelfRow(folder: url, source: .registry, archived: entry.archived, teka: Teka.read(url)))
        }
        for url in picked.map(\.standardizedFileURL) where seen.insert(url.path).inserted {
            rows.append(ShelfRow(folder: url, source: .picked, archived: false, teka: Teka.read(url)))
        }
        return rows
    }
}
