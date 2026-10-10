import Darwin
import Foundation
import SpravaKit

extension Backup {
    package var dir: URL { support.appendingPathComponent("backup", isDirectory: true) }
    package var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    var stateURL: URL { dir.appendingPathComponent("state.json") }

    /// The backup settings. Only a missing file is "not set up"; unreadable or malformed data stops maintenance.
    public func settings() throws -> Settings {
        let data: Data
        switch SafeFile.read(settingsURL, limit: 1024 * 1024) {
        case .missing:
            // SafeFile also reports ENOTDIR as missing. Only an actually absent settings entry is fresh.
            var info = stat()
            guard lstat(settingsURL.path, &info) != 0, errno == ENOENT else {
                throw Failure(message: "backup settings cannot be read; nothing was changed (\(settingsURL.path))")
            }
            return Settings()
        case .ok(let read):
            data = read
        case .refused, .unreadable:
            throw Failure(message: "backup settings cannot be read; nothing was changed (\(settingsURL.path))")
        }
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            throw Failure(message: "backup settings are unreadable; nothing was changed (\(settingsURL.path))")
        }
        return settings
    }

    func save(_ settings: Settings) throws {
        try AtomicFile.makePrivateFolder(dir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(settings), to: settingsURL)
    }

    /// The backup's records. Only a missing directory entry is fresh; unreadable or malformed data fails closed.
    func state() throws -> State {
        // Complete manifests can be large. Keep a defensive cap that remains ample for legitimate saved state.
        switch SafeFile.read(stateURL, limit: 256 * 1024 * 1024) {
        case .missing:
            // SafeFile also maps ENOTDIR to missing. Damaged parent state is never a fresh backup state.
            var info = stat()
            guard lstat(stateURL.path, &info) != 0, errno == ENOENT else {
                throw Failure(message: "backup state is unreadable; nothing was changed (\(stateURL.path))")
            }
            return State()
        case .ok(let data):
            guard let state = try? JSONDecoder().decode(State.self, from: data) else {
                throw Failure(message: "backup state is unreadable; nothing was changed (\(stateURL.path))")
            }
            return state
        case .refused, .unreadable:
            throw Failure(message: "backup state is unreadable; nothing was changed (\(stateURL.path))")
        }
    }

    func save(_ state: State) throws {
        try AtomicFile.makePrivateFolder(dir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(state), to: stateURL)
    }

    /// Throws when the settings cannot be read, which is not the same as not set up.
    public var isConfigured: Bool { get throws { try settings().primary != nil && key != nil } }

    /// The default mirror: a folder in the person's iCloud Drive.
    public static var defaultPrimary: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/Sprava Backup", isDirectory: true)
    }

    /// Restic for the repository at `path`, pinned by saved settings or by `candidate` before those are saved.
    func engine(_ path: String?, settings candidate: Settings? = nil) throws -> Restic {
        guard let path, let key else { throw Failure(message: "backup is not set up") }
        guard let binary = resticBinary else { throw Failure(message: "restic is missing from this installation") }
        // Sprava never runs a binary it did not set up (architecture 3.5).
        if let pinned = try (candidate ?? settings()).resticSHA256, Restic.sha256(of: binary) != pinned {
            throw Failure(message: "restic changed since backup was set up; set it up again to trust the new one")
        }
        return Restic(binary: binary, repository: URL(fileURLWithPath: path, isDirectory: true), key: key,
                      support: support, expectedSHA256: try (candidate ?? settings()).resticSHA256)
    }
}

