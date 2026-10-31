import Brains
import Foundation

/// Discover software only, never a Claude profile or credential. Runtime launch validates the signature again.
public enum ClaudeInstallation {
    public static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let versions = home.appendingPathComponent(".local/share/claude/versions", isDirectory: true)
        let installed = (try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
        let candidates = [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                          URL(fileURLWithPath: "/usr/local/bin/claude")] + installed.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }
        // Keep a verified native symlink as the stable entry point across Claude updates. Every launch
        // resolves and validates it again; a later replacement by a shim is refused, never executed.
        return candidates.first {
            let native = $0.resolvingSymlinksInPath()
            return FileManager.default.isExecutableFile(atPath: native.path) && ClaudeReadLaunch.isNativeInstallation(native)
        }
    }
}
