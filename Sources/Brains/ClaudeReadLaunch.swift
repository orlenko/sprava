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
    /// The agent's shell is a whole one (decisions.md D36): what holds it is the sandbox, not a list of commands. Its programs are those
    /// the system or Homebrew installed (`programFolders`), and nothing written to the binder or the session's home can run or load. It can
    /// start other programs, and through a program able to make arbitrary system calls read what the person's other programs show in their
    /// environment, which no sandbox rule stops (kern.procargs2, seen 2026-11-02). The author accepted that.
    static let allowedTools = ["Read", "Write", "Edit", "Glob", "Grep", "Bash"]
    /// Where a program may run from. Homebrew's links lead into its Cellar, and the sandbox compares the path they lead to.
    static let programFolders = ["/bin", "/usr/bin", "/usr/sbin", "/sbin", "/usr/libexec", "/Library/Developer/CommandLineTools",
                                 "/opt/homebrew/bin", "/opt/homebrew/sbin", "/opt/homebrew/Cellar", "/opt/homebrew/opt", "/usr/local/bin", "/usr/local/Cellar", "/usr/local/opt"]
    /// The only system services the shell can talk to. A system service works outside the sandbox on the caller's behalf, so with a whole
    /// shell each one is a way out: Launch Services and Apple events reach the person's apps, preferences and Spotlight read and write beyond the binder.
    /// The system log is closed too: what a command writes there would be binder text outside the binder.
    static let systemServices = ["com.apple.system.opendirectoryd.libinfo", "com.apple.system.notification_center"]
    package enum Refused: Error, Equatable { case unsupportedInstallation, managedPolicy, unsafeHome, invalidInput }
    /// The models a launch may name. A binder's conversation is Opus; reading one intake document in the clerk's place is
    /// Sonnet (decisions.md D40). A type, not a string, so nothing else reaches the command line.
    package enum Model: String, Sendable { case opus, sonnet }
    package struct Prepared: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        package let launch: ClaudeReadOnlyTurn.Launch
        package let programHash: String
        package var description: String { "<private Claude launch>" }
        package var debugDescription: String { description }
    }

    /// Verify the vendor signature on every preparation. Connection setup checks the installed
    /// CLI's protocol instead of requiring a particular release or executable filename.
    package static func prepare(program: URL, support: URL, connectionID: UUID, sessionID: UUID, credential: String,
                                policy: String, reach: Reach? = nil, appTools: ClaudeAppTools? = nil, model: Model = .opus,
                                onSpawn: @escaping @Sendable (pid_t) throws -> Void) throws -> Prepared {
        let program = program.resolvingSymlinksInPath()
        let hash = try installationHash(program)
        try refuseManagedPolicy()
        let home = support.appendingPathComponent("brains/read-homes/\(connectionID.uuidString)/\(sessionID.uuidString)", isDirectory: true)
        let launch = try plan(program: program, home: home, sessionID: sessionID,
                              credential: credential, policy: policy, reach: reach, appTools: appTools, model: model, onSpawn: onSpawn)
        return Prepared(launch: launch, programHash: hash)
    }

    /// Also used by deterministic fixture tests. Production callers cannot bypass prepare's signature
    /// and managed-source checks: this plan builder is internal to Brains, not a package API.
    /// The CLI records its built-in plugin here during a turn (`plugins/store/cc-plugin-agents-md_builtin-<hex>.json`, 92 bytes
    /// in 2.1.316), so a session's next turn finds it. That record is not customization and is allowed. Anything else under
    /// `plugins`, a link or a larger file included, is refused as before.
    static func holdsOnlyTheCLIsOwnRecords(plugins: URL) -> Bool {
        var info = stat()
        guard lstat(plugins.path, &info) == 0 else { return errno == ENOENT }
        let manager = FileManager.default
        guard info.st_mode & S_IFMT == S_IFDIR, let top = try? manager.contentsOfDirectory(atPath: plugins.path), top.allSatisfy({ $0 == "store" }) else { return false }
        guard !top.isEmpty else { return true }
        let store = plugins.appendingPathComponent("store")
        guard lstat(store.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, let records = try? manager.contentsOfDirectory(atPath: store.path) else { return false }
        return records.allSatisfy { name in
            name.wholeMatch(of: /cc-plugin-[a-z0-9-]+_builtin-[0-9a-f]+\.json/) != nil
                && lstat(store.appendingPathComponent(name).path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size <= 1024
        }
    }

    static func plan(program: URL, home: URL, sessionID: UUID, credential: String, policy: String, reach: Reach? = nil, appTools: ClaudeAppTools? = nil,
                     model: Model = .opus, onSpawn: @escaping @Sendable (pid_t) throws -> Void = { _ in }) throws -> ClaudeReadOnlyTurn.Launch {
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
        for name in ["CLAUDE.md", "AGENTS.md", ".mcp.json", "settings.json", "settings.local.json", "hooks", "agents", "skills"] {
            if lstat(home.appendingPathComponent("config/" + name).path, &info) == 0 || errno != ENOENT { throw Refused.unsafeHome }
        }
        guard holdsOnlyTheCLIsOwnRecords(plugins: home.appendingPathComponent("config/plugins")) else { throw Refused.unsafeHome }
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
        let appNames = appTools?.names ?? []
        let toolArguments = reach == nil
            ? (appNames.isEmpty ? ["--tools", "", "--disallowedTools", "*"] : ["--tools", "", "--allowedTools", appNames.joined(separator: ",")])
            : ["--tools", toolList, "--allowedTools", (allowedTools + appNames).joined(separator: ",")]
        let servers = appTools == nil ? "{\"mcpServers\":{}}" : JSONWriter.compact(.obj([("mcpServers", .obj([(ClaudeAppTools.server, .obj([("type", .str("sdk")), ("name", .str(ClaudeAppTools.server))]))]))]))
        if let reach {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            // `git` and `python3` in /usr/bin ask which developer folder to use, and the person's choice may be one the sandbox does not reach.
            environment["DEVELOPER_DIR"] = "/Library/Developer/CommandLineTools"
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
                    "--permission-mode", "dontAsk", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", servers,
                    "--settings", "{\"disableAllHooks\":true}", "--model", model.rawValue, "--max-budget-usd", reach == nil ? "2" : "10",
                    "--append-system-prompt-file", home.appendingPathComponent("app-policy.txt").path]
        return ClaudeReadOnlyTurn.Launch(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: args,
                                        environment: environment, directory: reach?.folder ?? home, sessionID: sessionID,
                                        tools: Set((reach == nil ? [] : tools) + appNames), secret: reach == nil ? nil : credential,
                                        appTools: appTools, onSpawn: onSpawn)
    }

    /// The walls of a binder's agent (conversation.md 18.3). It reads and writes its binder and its own home, and nothing
    /// else of the person's: reads are closed except for those and the folders of system files, programs and libraries. `.sprava`, the catalog and the
    /// dashboard have one writer, Sprava, and the instruction files one, the person: the agent may only read them. It runs only what is in `programFolders`, which the rules
    /// below keep from the person's other apps, clipboard and Keychain, and no program or library from a writable folder can run or load. Its only way out is the proxy's port: name lookups,
    /// direct connections and listening on a port fail whatever a command tries, so nothing read can leave except to the model. A key file can be
    /// deleted without being read. Renaming one first would get past that name rule: it stops an accidental read, it is not
    /// a wall.
    static func sandbox(home: URL, program: URL, reach: Reach, session: UUID) -> String {
        func q(_ value: String) -> String { JSONWriter.compact(.str(value)) }
        let binder = reach.folder.path
        var escaped = ""
        for character in binder { if "\\^$.|?*+()[]{}".contains(character) { escaped.append("\\") }; escaped.append(character) }
        let keyFiles = "^" + escaped + "/(.*/)?(\\.env(\\..*)?|\\.netrc|id_rsa[^/]*|id_ecdsa[^/]*|id_ed25519[^/]*|age-identity[^/]*|[^/]*credentials[^/]*|[^/]*\\.keychain[^/]*|token[^/]*\\.json|[^/]*\\.(pem|key|p12|pfx|age))$"
        return """
        (version 1)
        (allow default)
        (deny file-read*)
        (allow file-read-metadata)
        (allow file-read* (literal "/") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/System") (subpath "/Library/Apple") (subpath "/Library/Developer/CommandLineTools") (subpath "/private/etc") (subpath "/private/var/db/timezone") (subpath "/dev/fd") (literal "/dev/null") (literal "/dev/zero") (literal "/dev/random") (literal "/dev/urandom") (literal "/dev/tty") (literal "/dev/dtracehelper"))
        (allow file-read* (subpath "/opt/homebrew/bin") (subpath "/opt/homebrew/sbin") (subpath "/opt/homebrew/lib") (subpath "/opt/homebrew/opt") (subpath "/opt/homebrew/Cellar") (subpath "/opt/homebrew/share"))
        (deny file-read* (subpath "/usr/local/var") (subpath "/usr/local/etc") (subpath "/private/etc/ssh"))
        (allow file-read* (subpath \(q(home.path))) (subpath \(q(binder))) (literal \(q(program.path))))
        (deny file-read-data (regex \(q(keyFiles))))
        (deny file-write* (require-all (require-not (subpath \(q(home.path)))) (require-not (subpath \(q(binder)))) (require-not (subpath "/dev/fd")) (require-not (literal "/dev/null")) (require-not (literal "/dev/tty"))))
        (deny file-write* (subpath \(q(binder + "/.sprava"))) (literal \(q(binder + "/catalog.json"))) (literal \(q(binder + "/DASHBOARD.md"))) (literal \(q(binder + "/AGENTS.md"))) (literal \(q(binder + "/CLAUDE.md"))))
        (deny file-write-mode (literal \(q(binder))))
        (deny file-write-flags (literal \(q(binder))))
        (deny mach-lookup)
        (allow mach-lookup \(systemServices.map { "(global-name \(q($0)))" }.joined(separator: " ")))
        (deny appleevent-send)
        (deny job-creation)
        (deny file-map-executable (subpath \(q(binder))) (subpath \(q(home.path))))
        (deny process-exec*)
        (allow process-exec (literal \(q(program.path))) \(programFolders.map { "(subpath \(q($0)))" }.joined(separator: " ")))
        (deny signal)
        (allow signal (target same-sandbox))
        (deny network-outbound)
        (allow network-outbound (remote ip \(q("localhost:\(reach.proxyPort)"))))
        (deny network-bind)
        (deny network-inbound)
        (deny ipc-sysv*)
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
