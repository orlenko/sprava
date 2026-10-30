import Foundation

/// Which build is running, read from the Info.plist that `scripts/build-app.sh` stamps: the version, the commit count
/// as CFBundleVersion and the short commit as SpravaCommit ("-dirty" when the tree differed from it). The app, the
/// runtime and the helpers all run from one bundle, so About, the heartbeat and Health say the same thing.
public enum BuildIdentity {
    static let commitKey = "SpravaCommit"

    /// "0.1.0 (412 · 119b640)", or "dev" outside a bundle (`swift run`, tests).
    public static func describe(_ info: [String: Any]?) -> String {
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "dev" }
        guard let version = aboutVersion(info) else { return short }
        return "\(short) (\(version))"
    }

    /// The part in parentheses, as the About panel shows it after the version: "412 · 119b640".
    public static func aboutVersion(_ info: [String: Any]?) -> String? {
        let version = info?["CFBundleVersion"] as? String
        let commit = info?[commitKey] as? String
        switch (version, commit) {
        case let (version?, commit?): return "\(version) · \(commit)"
        case let (version?, nil): return version
        case let (nil, commit?): return commit
        case (nil, nil): return nil
        }
    }

    public static let current = describe(Bundle.main.infoDictionary)
}
