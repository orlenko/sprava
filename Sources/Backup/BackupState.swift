import Foundation
import SpravaKit

extension Backup {
    package var dir: URL { support.appendingPathComponent("backup", isDirectory: true) }
    package var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    var stateURL: URL { dir.appendingPathComponent("state.json") }

    /// The backup folder, held open so every read, temporary write and rename stays in the folder that was checked:
    /// a link put in place of it, or of the support folder, is refused rather than followed. Nil when it is absent.
    func backupDirectory(create: Bool) throws -> StateDirectory? {
        guard let root = try StateDirectory.open(support, create: create) else { return nil }
        return try root.directory("backup", create: create)
    }

    /// One file in the backup folder; nil only when it, or a folder above it, is absent.
    func readBackupFile(_ name: String, limit: Int, what: String) throws -> Data? {
        let unreadable = Failure(message: "\(what) cannot be read; nothing was changed (\(dir.appendingPathComponent(name).path))")
        do {
            guard let directory = try backupDirectory(create: false) else { return nil }
            switch try directory.read(name, limit: limit) {
            case .missing: return nil
            case .ok(let data): return data
            case .refused, .unreadable: throw unreadable
            }
        } catch let failure as Failure { throw failure } catch { throw unreadable }
    }

    func writeBackupFile(_ data: Data, to name: String, what: String) throws {
        do {
            guard let directory = try backupDirectory(create: true) else { throw Failure(message: "the backup folder is missing") }
            try directory.write(data, to: name)
        } catch {
            throw Failure(message: "\(what) could not be saved (\(error))")
        }
    }

    /// The backup settings. Only a missing file is "not set up"; unreadable or malformed data stops maintenance.
    public func settings() throws -> Settings {
        guard let data = try readBackupFile("settings.json", limit: 1024 * 1024, what: "backup settings") else { return Settings() }
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            throw Failure(message: "backup settings are unreadable; nothing was changed (\(settingsURL.path))")
        }
        return settings
    }

    func save(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeBackupFile(try encoder.encode(settings), to: "settings.json", what: "backup settings")
    }

    /// The backup's records. Only a missing file is fresh; unreadable or malformed data fails closed.
    func state() throws -> State {
        // Complete manifests can be large. Keep a defensive cap that remains ample for legitimate saved state.
        guard let data = try readBackupFile("state.json", limit: 256 * 1024 * 1024, what: "backup state") else { return State() }
        guard let state = try? JSONDecoder().decode(State.self, from: data) else {
            throw Failure(message: "backup state is unreadable; nothing was changed (\(stateURL.path))")
        }
        return state
    }

    func save(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeBackupFile(try encoder.encode(state), to: "state.json", what: "backup state")
    }

    /// Throws when the settings cannot be read, which is not the same as not set up.
    /// Settings without a restic pin are not set up: `engine` runs nothing until setup checks restic again.
    public var isConfigured: Bool { get throws { Self.isConfigured(try settings(), key: key) } }

    static func isConfigured(_ settings: Settings, key: String?) -> Bool {
        settings.primary != nil && settings.resticSHA256 != nil && key != nil
    }

    /// The default mirror: a folder in the person's iCloud Drive.
    public static var defaultPrimary: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/Sprava Backup", isDirectory: true)
    }

    /// Restic for the repository at `path`, pinned by saved settings or by `candidate` before those are saved.
    func engine(_ path: String?, settings candidate: Settings? = nil) throws -> Restic {
        guard let path, let key else { throw Failure(message: "backup is not set up") }
        guard let binary = resticBinary else { throw Failure(message: "restic is missing from this installation") }
        // Sprava never runs a binary it did not set up (architecture 3.5): settings without a pin, such as older
        // ones, trust nothing until setup runs again and pins the restic it checked.
        guard let pinned = try (candidate ?? settings()).resticSHA256 else {
            throw Failure(message: "restic has not been checked since backup was set up; set it up again to trust it")
        }
        guard Restic.sha256(of: binary) == pinned else {
            throw Failure(message: "restic changed since backup was set up; set it up again to trust the new one")
        }
        return Restic(binary: binary, repository: URL(fileURLWithPath: path, isDirectory: true), key: key,
                      support: support, expectedSHA256: pinned)
    }
}

