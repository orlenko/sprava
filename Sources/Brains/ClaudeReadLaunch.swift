import Darwin
import Foundation
import Security
import SpravaKit

/// The supported tool-free installed-CLI launch, not permission to send binder data. The runtime
/// still authenticates/consents the read connection and verifies its effective account/setup first.
/// No personal Claude profile is read and no surrounding process environment is inherited.
package enum ClaudeReadLaunch {
    package static let supportedVersion = "2.1.304"
    package enum Refused: Error, Equatable { case unsupportedInstallation, managedPolicy, unsafeHome, invalidInput }
    package struct Prepared: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        package let launch: ClaudeReadOnlyTurn.Launch
        package let programHash: String
        package var description: String { "<private Claude launch>" }
        package var debugDescription: String { description }
    }

    /// Pinned vendor/version checks happen on every preparation. A newer binary needs compatibility
    /// validation before support is widened; an arbitrary executable is never a model-selected setting.
    package static func prepare(program: URL, support: URL, connectionID: UUID, sessionID: UUID, credential: String,
                                policy: String, onSpawn: @escaping @Sendable (pid_t) throws -> Void) throws -> Prepared {
        let program = program.resolvingSymlinksInPath()
        let hash = try installationHash(program)
        try refuseManagedPolicy()
        let home = support.appendingPathComponent("brains/read-homes/\(connectionID.uuidString)/\(sessionID.uuidString)", isDirectory: true)
        let launch = try plan(program: program, home: home, sessionID: sessionID,
                              credential: credential, policy: policy, onSpawn: onSpawn)
        return Prepared(launch: launch, programHash: hash)
    }

    /// Also used by deterministic fixture tests. Production callers cannot bypass prepare's signature
    /// and managed-source checks: this plan builder is internal to Brains, not a package API.
    static func plan(program: URL, home: URL, sessionID: UUID, credential: String, policy: String,
                     onSpawn: @escaping @Sendable (pid_t) throws -> Void = { _ in }) throws -> ClaudeReadOnlyTurn.Launch {
        guard program.isFileURL, home.isFileURL, !credential.isEmpty, credential.utf8.count <= 16_384,
              !credential.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              policy.utf8.count <= 1024 * 1024,
              [program.path, home.path].allSatisfy({ !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw Refused.invalidInput
        }
        try AtomicFile.makePrivateFolder(home)
        let home = home.resolvingSymlinksInPath()
        guard let directory = try StateDirectory.open(home) else { throw Refused.unsafeHome }
        var info = stat()
        guard lstat(home.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            throw Refused.unsafeHome
        }
        _ = try directory.directory("config", create: true)
        _ = try directory.directory("tmp", create: true)
        // Customization is never recovered from a native cache. Terminal sessions are not offered by this pilot.
        for name in ["CLAUDE.md", "AGENTS.md", ".claude", ".mcp.json", "settings.json", "settings.local.json", "plugins", "hooks", "agents", "skills"] {
            if lstat(home.appendingPathComponent(name).path, &info) == 0 || errno != ENOENT { throw Refused.unsafeHome }
        }
        for name in ["CLAUDE.md", "AGENTS.md", ".mcp.json", "settings.json", "settings.local.json", "plugins", "hooks", "agents", "skills"] {
            if lstat(home.appendingPathComponent("config/" + name).path, &info) == 0 || errno != ENOENT { throw Refused.unsafeHome }
        }
        try directory.write(Data(policy.utf8), to: "app-policy.txt")
        try directory.write(Data(sandbox(home: home, program: program).utf8), to: "app-sandbox.sb")
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            "HOME": home.path, "CLAUDE_CONFIG_DIR": home.appendingPathComponent("config").path,
            "CLAUDE_CODE_TMPDIR": home.appendingPathComponent("tmp").path, "TMPDIR": home.appendingPathComponent("tmp").path,
            "CLAUDE_CODE_OAUTH_TOKEN": credential, "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
            "DISABLE_TELEMETRY": "1"
        ]
        let args = ["-f", home.appendingPathComponent("app-sandbox.sb").path, program.path,
                    "--safe-mode", "--restricted", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--verbose", "--replay-user-messages", "--tools", "", "--disallowedTools", "*",
                    "--permission-mode", "dontAsk", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--settings", "{\"disableAllHooks\":true}", "--model", "sonnet", "--max-budget-usd", "2",
                    "--append-system-prompt-file", home.appendingPathComponent("app-policy.txt").path]
        return ClaudeReadOnlyTurn.Launch(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: args,
                                        environment: environment, directory: home, sessionID: sessionID, onSpawn: onSpawn)
    }

    static func sandbox(home: URL, program: URL) -> String {
        func q(_ value: String) -> String { JSONWriter.compact(.str(value)) }
        return """
        (version 1)
        (allow default)
        (deny file-read* (require-all (subpath "/Users") (require-not (subpath \(q(home.path)))) (require-not (literal \(q(program.path))))))
        (deny file-read* (subpath "/Volumes") (subpath "/Library/Keychains"))
        (deny mach-lookup (global-name "com.apple.securityd") (global-name "com.apple.securityd.xpc"))
        (deny file-write* (require-all (require-not (subpath \(q(home.path)))) (require-not (subpath "/dev/fd")) (require-not (literal "/dev/null"))))
        (deny process-exec (require-not (literal \(q(program.path)))))
        (deny process-fork)
        """
    }

    private static func installationHash(_ program: URL) throws -> String {
        guard program.lastPathComponent == supportedVersion else { throw Refused.unsupportedInstallation }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(program as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw Refused.unsupportedInstallation }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as NSDictionary?, values[kSecCodeInfoTeamIdentifier as String] as? String == "Q6L2SF6YDW",
              let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { throw Refused.unsupportedInstallation }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func refuseManagedPolicy() throws {
        // Presence only, never contents of a managed/profile/credential file. Unknown access fails closed.
        let paths = ["/Library/Application Support/ClaudeCode/managed-settings.json",
                     "/Library/Application Support/ClaudeCode/managed-settings.d",
                     "/Library/Application Support/ClaudeCode/managed-mcp.json",
                     "/Library/Managed Preferences/com.anthropic.claudecode.plist",
                     "/Library/Managed Preferences/\(NSUserName())/com.anthropic.claudecode.plist",
                     "/Library/Preferences/com.anthropic.claudecode.plist"]
        for path in paths {
            var info = stat()
            if lstat(path, &info) == 0 || errno != ENOENT { throw Refused.managedPolicy }
        }
    }
}
