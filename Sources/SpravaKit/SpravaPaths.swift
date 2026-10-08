import Foundation

/// Where Sprava keeps its own state: `$SPRAVA_SUPPORT_DIR`, else `~/Library/Application Support/Sprava`.
/// Nothing Sprava keeps about a binder before adoption lives inside the binder (mvp.md feature 1).
public enum SpravaPaths {
    public static func supportDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let env = environment["SPRAVA_SUPPORT_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sprava", isDirectory: true)
    }
}
