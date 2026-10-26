import Foundation
import SpravaKit

/// The setup steps before a binder is connected: does a server answer, and which folders does an account see.
/// Each runs the same isolated worker in a disposable private folder under `capture/imap-checks/`.
public enum IMAPServerCheck {
    public enum Result: String, Sendable {
        case ok
        /// The server takes no password, only OAuth (Microsoft 365, Google without an app password).
        case oauthOnly = "oauth_only"
        /// TLS works, but the certificate does not verify; `Answer.fingerprint` says which one was offered.
        case untrusted
        case tls, unreachable, unknownHost = "unknown_host", noAnswer = "no_answer", notIMAP = "not_imap"
    }
    public struct Answer: Sendable, Equatable {
        public let result: Result
        public let fingerprint: String?
        public init(result: Result, fingerprint: String? = nil) { self.result = result; self.fingerprint = fingerprint }
    }

    public static func probe(_ account: IMAPAccount, support: URL) throws -> Answer {
        try inPrivateFolder(support) { home in
            let status = try IMAPNativeFetch.invoke(["--mode=probe"] + IMAPNativeFetch.server(account), input: nil, home: home)
            guard status == 0, let object = try result(home), let name = object["result"]?.stringValue, let value = Result(rawValue: name) else {
                throw IMAPIntakeImport.Refused.unavailable
            }
            let fingerprint = object["fingerprint"]?.stringValue
            guard value != .untrusted || fingerprint.map({ $0.utf8.count == 64 && $0.allSatisfy(\.isHexDigit) }) == true else {
                throw IMAPIntakeImport.Refused.unavailable
            }
            return Answer(result: value, fingerprint: value == .untrusted ? fingerprint : nil)
        }
    }

    /// The folders the account can open, INBOX first. Throws `authentication` when the server refuses the sign-in.
    public static func folders(_ account: IMAPAccount, password: String, support: URL) throws -> [String] {
        try inPrivateFolder(support) { home in
            try IMAPNativeFetch.check(IMAPNativeFetch.invoke(["--mode=folders"] + IMAPNativeFetch.server(account),
                                                             input: IMAPNativeFetch.credentials(account, password), home: home))
            guard let names = try result(home)?["folders"]?.arrayValue, names.count <= 2_000 else { throw IMAPIntakeImport.Refused.invalidExport }
            return try names.map {
                guard let name = $0.stringValue, !name.isEmpty, name.utf8.count <= 1_024 else { throw IMAPIntakeImport.Refused.invalidExport }
                return name
            }
        }
    }

    private static func result(_ home: URL) throws -> JSONObject? {
        guard let directory = try StateDirectory.open(home), case .ok(let data) = try directory.read("result.json", limit: 1024 * 1024) else { return nil }
        let parsed = try JSONParser.parse(data)
        guard parsed.safety.isSafe else { return nil }
        return parsed.value.objectValue
    }

    private static func inPrivateFolder<T>(_ support: URL, _ body: (URL) throws -> T) throws -> T {
        let root = support.appendingPathComponent("capture/imap-checks")
        guard let checks = try StateDirectory.open(root, create: true) else { throw IMAPIntakeImport.Refused.unavailable }
        let name = UUID().uuidString
        guard try checks.directory(name, create: true) != nil else { throw IMAPIntakeImport.Refused.unavailable }
        let home = root.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: home) }
        return try body(home)
    }
}
