import Darwin
import Foundation

/// Sprava's own state files (producers, filing list, unfiled digests): a missing file reads as nil, so the caller
/// starts empty; a file that exists but cannot be read or decoded throws, so nothing ever saves over it (the rule
/// of `ShelfStore.readFolders`). Reads and writes go through a `StateDirectory` handle on the file's folder, so a
/// link in place of the file or its folder is refused rather than followed, and a folder swapped for a link
/// between the check and the open cannot redirect them.
public enum StateFile {
    /// A state file that exists but cannot be read or decoded. `ShelfStore.Unreadable` is this type.
    public struct Unreadable: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "\(path) exists but cannot be read; it was left as it is" }

        package init(path: String) { self.path = path }
    }

    /// State files are small; the limit only keeps a runaway file from being read whole into memory.
    static let limit = 256 * 1024 * 1024

    package static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) throws -> T? {
        try read(type, from: url, decoder: decoder, beforeOpen: {})
    }

    /// Test boundary: the folder can be replaced after it is validated and before the file is opened.
    static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder,
                                   beforeOpen: () throws -> Void) throws -> T? {
        let outcome: SafeFile.Outcome
        do {
            guard let folder = try StateDirectory.open(url.deletingLastPathComponent()) else { return nil }
            outcome = try folder.read(url.lastPathComponent, limit: limit, beforeOpen: beforeOpen)
        } catch { throw Unreadable(path: url.path) }
        switch outcome {
        case .missing: return nil
        case .ok(let data):
            guard let value = try? decoder.decode(T.self, from: data) else { throw Unreadable(path: url.path) }
            return value
        case .refused, .unreadable: throw Unreadable(path: url.path)
        }
    }

    /// Replaces the file whole through a handle on its folder, creating the folder (and missing parents) when
    /// needed. Throws when the folder is a link, is not this user's, or is writable by others; when a link or a
    /// folder stands in the file's place; and when the data is larger than a read accepts, so a runaway encoder
    /// never replaces a readable file with one no read can take.
    package static func write(_ data: Data, to url: URL) throws {
        try write(data, to: url, beforeOpen: {})
    }

    static func write(_ data: Data, to url: URL, beforeOpen: () throws -> Void) throws {
        guard data.count <= limit else { throw AtomicFile.Failure(step: "state file too large", code: EFBIG) }
        guard let folder = try StateDirectory.open(url.deletingLastPathComponent(), create: true) else {
            throw AtomicFile.Failure(step: "open state directory", code: ENOENT)
        }
        try folder.write(data, to: url.lastPathComponent, beforeOpen: beforeOpen)
    }
}
