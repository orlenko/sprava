import Foundation
import SpravaKit

/// Opaque binder ids (`b1`, `b2`, ...), kept in Sprava's own state. Logs, the heartbeat and notifications name
/// binders only by these, never by `meta.name` or the folder name (architecture 3.7).
public struct BinderIDs: Codable, Sendable {
    public var byPath: [String: String] = [:]
    public var next = 1

    public init() {}

    public struct Unreadable: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "\(path) exists but cannot be read; it was left as it is" }
    }

    /// The ids. A missing file is a fresh mapping; one that exists but cannot be read or decoded throws, so new
    /// ids are never handed out over the old ones (b1 must keep naming the same binder).
    public static func load(_ url: URL) throws -> BinderIDs {
        do { return try StateFile.read(BinderIDs.self, from: url) ?? BinderIDs() } catch { throw Unreadable(path: url.path) }
    }

    public mutating func id(for folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        if let id = byPath[path] { return id }
        let id = "b\(next)"
        next += 1
        byPath[path] = id
        return id
    }

    public func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try StateFile.write(try encoder.encode(self), to: url)
    }
}
