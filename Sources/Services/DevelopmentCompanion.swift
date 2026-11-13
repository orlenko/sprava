import Companion
import CryptoKit
import Darwin
import Foundation
import SpravaKit

/// Development-only credentials for the companion: one private file per account under the development support
/// folder, never the Keychain, so a development runtime or `sprava dev-phone` can pair against a local relay with
/// invented data. Each file is written once (a temporary file linked into place, which fails if the name exists),
/// matching the Keychain's insert-if-absent contract. The bytes are not encrypted: never use this with real data.
public struct DevelopmentCompanionCredentials: CompanionCredentialStorage {
    public struct Refused: Error, CustomStringConvertible {
        public var description: String { "development credentials live only in the development support folder" }
    }
    let folder: URL

    /// Refuses any support folder but the development one (`DevelopmentSupport.directory`).
    public init(support: URL, development: URL = DevelopmentSupport.directory()) throws {
        guard support.standardizedFileURL.path == development.standardizedFileURL.path else { throw Refused() }
        folder = support.appendingPathComponent("companion/dev-credentials", isDirectory: true)
    }

    /// Account names carry relay origins; a hash keeps them out of file names.
    private func file(_ account: String) -> URL {
        folder.appendingPathComponent(SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    public func read(account: String) throws -> Data? {
        do { return try Data(contentsOf: file(account)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch { throw CompanionCredentialError.unavailable }
    }
    public func insert(account: String, bytes: Data) throws -> Bool {
        try AtomicFile.makePrivateFolder(folder)
        let temp = folder.appendingPathComponent(".\(UUID().uuidString.lowercased()).tmp")
        defer { unlink(temp.path) }
        try AtomicFile.write(bytes, to: temp)
        if link(temp.path, file(account).path) == 0 { return true }
        guard errno == EEXIST else { throw CompanionCredentialError.unavailable }
        return false
    }
    public func remove(account: String) throws {
        if unlink(file(account).path) != 0 && errno != ENOENT { throw CompanionCredentialError.unavailable }
    }
}

extension CompanionRuntimeRequests {
    /// The development runtime's Phone actions: the same handlers over the development state and credentials.
    public static func development(support: URL, watch: WatchBox?,
                                   developmentSupport: URL = DevelopmentSupport.directory()) throws -> Self {
        try Self(database: support.appendingPathComponent("companion/state.sqlite"),
                 secrets: DevelopmentCompanionCredentials(support: support, development: developmentSupport), watch: watch)
    }
}
