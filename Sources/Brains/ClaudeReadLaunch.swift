import Darwin
import Foundation
import Security
import SpravaKit

/// The supported installed-CLI launch, not permission to send binder data. The runtime
/// still authenticates/consents the read connection and verifies its effective account/setup first.
/// No personal Claude profile is read and no surrounding process environment is inherited.
/// With `Reach` it has file and shell tools inside one binder, walled by the operating system (`sandbox`), never by
/// asking the model; without, it has no tools at all, as the setup check needs.
package enum ClaudeReadLaunch {
    /// What a binder's agent may touch: the folder, and the one loopback port that leads out.
    package struct Reach: Sendable {
        package let folder: URL
        package let proxyPort: UInt16
        package init(folder: URL, proxyPort: UInt16) { self.folder = folder; self.proxyPort = proxyPort }
    }
    static let tools = ["Read", "Write", "Edit", "Glob", "Grep", "Bash"]
    /// All the agent's commands may run: file tools. No scripting language, compiler or anything from a writable folder, because
    /// a program that can make arbitrary system calls can read another process's environment, and so any credential one of the
    /// person's programs holds there; no sandbox rule stops that read (kern.procargs2, seen 2026-11-02). None of these can.
    static let commandPrograms: [String] =
        ["sh", "bash", "zsh", "ls", "cat", "cp", "mv", "rm", "mkdir", "rmdir", "ln", "chmod", "pwd", "echo", "date", "test", "expr", "sleep", "realpath"].map { "/bin/" + $0 }
        + ["find", "grep", "egrep", "fgrep", "sed", "awk", "head", "tail", "wc", "sort", "uniq", "cut", "tr", "diff", "cmp", "file", "stat", "touch", "basename", "dirname",
           "xargs", "env", "tar", "bsdtar", "gzip", "gunzip", "zip", "unzip", "tee", "which", "true", "false", "du", "fold", "paste", "comm", "nl", "rev", "readlink",
           "mktemp", "iconv", "textutil", "uname", "id", "whoami"].map { "/usr/bin/" + $0 }
        + ["/usr/libexec/path_helper"]
    package enum Refused: Error, Equatable { case unsupportedInstallation, managedPolicy, unsafeHome, invalidInput }
    package struct Prepared: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        package let launch: ClaudeReadOnlyTurn.Launch
        package let programHash: String
        package var description: String { "<private Claude launch>" }
        package var debugDescription: String { description }
    }

    /// Verify the vendor signature on every preparation. Connection setup checks the installed
    /// CLI's protocol instead of requiring a particular release or executable filename.
    package static func prepare(program: URL, support: URL, connectionID: UUID, sessionID: UUID, credential: String,
                                policy: String, reach: Reach? = nil, onSpawn: @escaping @Sendable (pid_t) throws -> Void) throws -> Prepared {
        let program = program.resolvingSymlinksInPath()
        let hash = try installationHash(program)
        try refuseManagedPolicy()
        let home = support.appendingPathComponent("brains/read-homes/\(connectionID.uuidString)/\(sessionID.uuidString)", isDirectory: true)
        let launch = try plan(program: program, home: home, sessionID: sessionID,
                              credential: credential, policy: policy, reach: reach, onSpawn: onSpawn)
        return Prepared(launch: launch, programHash: hash)
    }

    /// Also used by deterministic fixture tests. Production callers cannot bypass prepare's signature
    /// and managed-source checks: this plan builder is internal to Brains, not a package API.
    static func plan(program: URL, home: URL, sessionID: UUID, credential: String, policy: String, reach: Reach? = nil,
                     onSpawn: @escaping @Sendable (pid_t) throws -> Void = { _ in }) throws -> ClaudeReadOnlyTurn.Launch {
        // The real path, which is what the sandbox compares: resolvingSymlinksInPath would strip /private from /private/var.
        let reach = try reach.map { reach -> Reach in
            guard let real = realpath(reach.folder.path, nil) else { throw Refused.invalidInput }
            defer { free(real) }
            return Reach(folder: URL(fileURLWithPath: String(cString: real), isDirectory: true), proxyPort: reach.proxyPort)
        }
        guard program.isFileURL, home.isFileURL, !credential.isEmpty, credential.utf8.count <= 16_384,
              !credential.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              policy.utf8.count <= 1024 * 1024,
              [program.path, home.path, reach?.folder.path ?? ""].allSatisfy({ !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
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
        try directory.write(Data((reach.map { sandbox(home: home, program: program, reach: $0, session: sessionID) } ?? sandbox(home: home, program: program)).utf8), to: "app-sandbox.sb")
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            "HOME": home.path, "CLAUDE_CONFIG_DIR": home.appendingPathComponent("config").path,
            "CLAUDE_CODE_TMPDIR": home.appendingPathComponent("tmp").path, "TMPDIR": home.appendingPathComponent("tmp").path,
            "CLAUDE_CODE_OAUTH_TOKEN": credential, "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
            "DISABLE_TELEMETRY": "1"
        ]
        let toolList = tools.joined(separator: ",")
        let toolArguments = reach == nil ? ["--tools", "", "--disallowedTools", "*"] : ["--tools", toolList, "--allowedTools", toolList]
        if let reach {
            let proxy = "http://127.0.0.1:\(reach.proxyPort)"
            environment["HTTPS_PROXY"] = proxy; environment["HTTP_PROXY"] = proxy
            // The person's token stays with the agent process. A process's environment can be read by another of the same user
            // whatever the sandbox says, so with commands running it arrives by pipe and is in no environment; the CLI also
            // strips such names from what its commands inherit.
            environment["CLAUDE_CODE_OAUTH_TOKEN"] = nil
            environment["CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"] = String(ClaudeTurnProcess.secretDescriptor)
            environment["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"
        }
        let args = ["-f", home.appendingPathComponent("app-sandbox.sb").path, program.path,
                    "--safe-mode", "--restricted", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--verbose", "--replay-user-messages"] + toolArguments + [
                    "--permission-mode", "dontAsk", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--settings", "{\"disableAllHooks\":true}", "--model", "sonnet", "--max-budget-usd", reach == nil ? "2" : "5",
                    "--append-system-prompt-file", home.appendingPathComponent("app-policy.txt").path]
        return ClaudeReadOnlyTurn.Launch(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: args,
                                        environment: environment, directory: reach?.folder ?? home, sessionID: sessionID,
                                        tools: reach == nil ? [] : Set(tools), secret: reach == nil ? nil : credential, onSpawn: onSpawn)
    }

    /// The walls of a binder's agent (conversation.md 18.3). It reads and writes its binder and its own home, and nothing
    /// else of the person's: reads are closed except for those and the folders of system files, programs and libraries. `.sprava`, the catalog and the
    /// dashboard have one writer, Sprava, and it may only read them. It runs only `commandPrograms`, none of
    /// which reach the person's other apps, clipboard or Keychain. Its only way out is the proxy's port: name lookups,
    /// direct connections and listening on a port fail whatever a command tries, so nothing read can leave except to the model. A key file can be
    /// deleted without being read. Renaming one first would get past that name rule: it stops an accidental read, it is not
    /// a wall.
    static func sandbox(home: URL, program: URL, reach: Reach, session: UUID) -> String {
        func q(_ value: String) -> String { JSONWriter.compact(.str(value)) }
        let binder = reach.folder.path
        var escaped = ""
        for character in binder { if "\\^$.|?*+()[]{}".contains(character) { escaped.append("\\") }; escaped.append(character) }
        let keyFiles = "^" + escaped + "/(.*/)?(\\.env(\\..*)?|\\.netrc|id_rsa[^/]*|id_ecdsa[^/]*|id_ed25519[^/]*|age-identity[^/]*|[^/]*credentials[^/]*|[^/]*\\.keychain[^/]*|token[^/]*\\.json|[^/]*\\.(pem|key|p12|pfx|age))$"
        let programs = commandPrograms + [program.path]
        return """
        (version 1)
        (allow default)
        (deny file-read*)
        (allow file-read-metadata)
        (allow file-read* (literal "/") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/System") (subpath "/Library/Apple") (subpath "/Library/Developer/CommandLineTools") (subpath "/private/etc") (subpath "/dev") (subpath "/private/var/db/timezone"))
        (allow file-read* (subpath "/opt/homebrew/bin") (subpath "/opt/homebrew/sbin") (subpath "/opt/homebrew/lib") (subpath "/opt/homebrew/opt") (subpath "/opt/homebrew/Cellar") (subpath "/opt/homebrew/share"))
        (deny file-read* (subpath "/usr/local/var") (subpath "/usr/local/etc") (subpath "/private/etc/ssh"))
        (allow file-read* (subpath \(q(home.path))) (subpath \(q(binder))) (literal \(q(program.path))))
        (deny file-read-data (regex \(q(keyFiles))))
        (deny file-write* (require-all (require-not (subpath \(q(home.path)))) (require-not (subpath \(q(binder)))) (require-not (subpath "/dev/fd")) (require-not (literal "/dev/null")) (require-not (literal "/dev/tty"))))
        (deny file-write* (subpath \(q(binder + "/.sprava"))) (literal \(q(binder + "/catalog.json"))) (literal \(q(binder + "/DASHBOARD.md"))))
        (deny file-write-mode (literal \(q(binder))))
        (deny file-write-flags (literal \(q(binder))))
        (deny mach-lookup (global-name "com.apple.securityd") (global-name "com.apple.securityd.xpc") (global-name "com.apple.coreservices.launchservicesd") (global-name "com.apple.pasteboard.1"))
        (deny appleevent-send)
        (deny job-creation)
        (deny process-exec*)
        (allow process-exec \(programs.map { "(literal \(q($0)))" }.joined(separator: " ")))
        (deny signal)
        (allow signal (target same-sandbox))
        (deny network-outbound)
        (allow network-outbound (remote ip \(q("localhost:\(reach.proxyPort)"))))
        (deny network-bind (local ip))
        (deny network-inbound (local ip))
        \(AgentContainment.rule(session: session))
        """
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

    static func installationHash(_ program: URL, validatedSignature: (URL) throws -> Data = signedInstallationHash) throws -> String {
        let hash = try validatedSignature(program)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    package static func isNativeInstallation(_ program: URL) -> Bool {
        (try? signedInstallationHash(program)) != nil
    }

    private static func signedInstallationHash(_ program: URL) throws -> Data {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(program as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw Refused.unsupportedInstallation }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as NSDictionary?, values[kSecCodeInfoTeamIdentifier as String] as? String == "Q6L2SF6YDW",
              let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { throw Refused.unsupportedInstallation }
        return hash
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
