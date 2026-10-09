import Darwin
import Foundation

/// Sprava's own state files (producers, filing list, unfiled digests): a missing file reads as nil, so the caller
/// starts empty; a file that exists but cannot be read or decoded throws, so nothing ever saves over it (the rule
/// of `ShelfStore.readFolders`).
public enum StateFile {
    /// A state file that exists but cannot be read or decoded. `ShelfStore.Unreadable` is this type.
    public struct Unreadable: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "\(path) exists but cannot be read; it was left as it is" }

        package init(path: String) { self.path = path }
    }

    package static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) throws -> T? {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            if errno == ENOENT { return nil }
            throw Unreadable(path: url.path)
        }
        guard let data = try? Data(contentsOf: url), let value = try? decoder.decode(T.self, from: data) else {
            throw Unreadable(path: url.path)
        }
        return value
    }
}
