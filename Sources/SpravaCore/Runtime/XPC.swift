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
    public static func load(support: URL) -> String {
        let url = support.appendingPathComponent("device-id")
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let id = UUID().uuidString.lowercased()
        try? AtomicFile.makePrivateFolder(support)
        try? AtomicFile.write(Data(id.utf8), to: url)
        return id
    }
}
