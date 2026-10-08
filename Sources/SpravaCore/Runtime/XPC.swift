import Foundation

/// The app ⇄ runtime protocol (architecture 2.1): one method carrying a JSON request and a JSON reply, so the
/// interface is versioned by the request's content and the same `Commands` code is tested in-process.
@objc public protocol SpravaRuntimeXPC {
    func handle(_ request: String, reply: @escaping (String) -> Void)
}

public enum XPCNames {
    public static let runtime = "ca.orlenko.sprava.runtime.xpc"
    /// Who may connect. With a Developer ID the requirement also pins the team; an ad-hoc build can pin only the
    /// identifier, which any same-user program could copy. Spike a (architecture 13) settles the release form.
    public static let appRequirement = #"identifier "ca.orlenko.sprava""#
}

/// This Mac's device id. The architecture keeps it in the Keychain as a this-device-only item (spike g); until
/// that spike, a random id in Sprava's own state.
public enum DeviceID {
    public struct Unreadable: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "\(path) exists but is not a device id; it was left as it is" }
    }

    /// The id every adopted binder's owner record names. It is made only when the file is absent, created
    /// exclusively so two processes starting at once agree, and always read back from disk. A file that exists
    /// but cannot be read throws: a new id would make every binder this Mac owns read-only here.
    public static func load(support: URL) throws -> String {
        let url = support.appendingPathComponent("device-id")
        if let id = try read(url) { return id }
        try AtomicFile.makePrivateFolder(support)
        let temp = support.appendingPathComponent(".device-id.\(UUID().uuidString.lowercased()).tmp")
        try AtomicFile.write(Data((UUID().uuidString.lowercased() + "\n").utf8), to: temp)
        defer { unlink(temp.path) }
        // link() never replaces an existing file: when another process got there first, its id wins.
        if link(temp.path, url.path) != 0, errno != EEXIST { throw AtomicFile.Failure(step: "link device-id", code: errno) }
        guard let id = try read(url) else { throw Unreadable(path: url.path) }
        return id
    }

    /// nil when the file is absent; throws when it exists and does not hold a lowercase UUID.
    static func read(_ url: URL) throws -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw Unreadable(path: url.path)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Unreadable(path: url.path) }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil else { throw Unreadable(path: url.path) }
        return id
    }
}
