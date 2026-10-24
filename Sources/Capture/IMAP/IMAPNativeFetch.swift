import CryptoKit
import Darwin
import Foundation
import SpravaKit

/// The built-in plugin runs the bundled raw-message synchronizer in isolated Python without a shell, inherited credentials,
/// personal home access or access to a binder. All child output is discarded, never logged.
public enum IMAPNativeFetch {
    public static func installedProgram() throws -> URL {
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            let launcher = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            // Homebrew's framework bin/python is a re-exec launcher. Start the actual interpreter
            // directly, so no child/re-exec permission needs to be added to the sandbox.
            let interpreter = launcher.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Python.app/Contents/MacOS/Python")
            let url = FileManager.default.isExecutableFile(atPath: interpreter.path) ? interpreter : launcher
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
               info.st_uid == getuid() || info.st_uid == 0, info.st_mode & 0o022 == 0,
               FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw IMAPIntakeImport.Refused.unavailable
    }
    public static func programHash() throws -> String {
        guard case .ok(let data) = SafeFile.read(try installedProgram(), limit: 128 * 1024 * 1024) else { throw IMAPIntakeImport.Refused.unavailable }
        return SHA256.hash(data: data + Data(IMAPExporterSource.script.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func run(_ config: BinderIMAPConnections.Configuration, directory: URL, messages: URL) throws {
        try run(config, directory: directory, messages: messages, cancelled: { false })
    }
    public static func run(_ config: BinderIMAPConnections.Configuration, directory: URL, messages: URL, cancelled: @Sendable () -> Bool) throws {
        let paths = try paths(program: installedProgram(), home: directory, environment: config.environment, messages: messages)
        let program = paths.program, directory = paths.home
        guard try programHash() == config.programHash, let state = try StateDirectory.open(directory) else { throw IMAPIntakeImport.Refused.unavailable }
        try state.createImmutable(Data(IMAPExporterSource.script.utf8), to: "imap-fetch.py")
        try state.write(Data(profile(program: program, home: directory, environment: paths.environment).utf8), to: "sandbox.sb")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = arguments(config, paths: paths)
        process.environment = environment(config, home: directory)
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(240)
        var limited = false
        while process.isRunning {
            if cancelled() || Date() > deadline || resident(process.processIdentifier) > 512 * 1024 * 1024 || ((try? size(directory)) ?? Int.max) > 256 * 1024 * 1024 {
                limited = true; process.terminate()
                Thread.sleep(forTimeInterval: 0.2)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        if !limited, process.terminationReason == .exit, process.terminationStatus == 21 { throw IMAPIntakeImport.Refused.authentication }
        guard !limited, process.terminationReason == .exit, process.terminationStatus == 0 else { throw IMAPIntakeImport.Refused.unavailable }
    }
    static func arguments(_ config: BinderIMAPConnections.Configuration, paths: Paths) -> [String] {
        // Isolated stdlib only: no site-packages, .pth hooks, user modules, shell or profile.
        var values = ["-f", paths.home.appendingPathComponent("sandbox.sb").path, paths.program.path,
            "-I", "-S", "-B", paths.home.appendingPathComponent("imap-fetch.py").path,
            "--folder=" + config.mailbox, "--target=" + paths.messages.path,
            "--env-file=" + paths.environment.path, "--port=" + String(config.port),
            "--search=" + config.search, "--from-contains=" + config.sender, "--subject-contains=" + config.subject]
        if config.startTLS { values.append("--starttls") }; return values
    }
    static func environment(_ config: BinderIMAPConnections.Configuration, home: URL) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "TMPDIR": home.path,
         "IMAP_MARK_READ": "false", "IMAP_TLS_REJECT_UNAUTHORIZED": "true", "IMAP_PORT": String(config.port),
         "IMAP_SECURE": config.startTLS ? "false" : "true", "IMAP_STARTTLS": config.startTLS ? "true" : "false"]
    }
    struct Paths {
        let program: URL, home: URL, environment: URL, messages: URL
    }
    static func physical(_ url: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard realpath(url.path, &buffer) != nil else { throw IMAPIntakeImport.Refused.unavailable }
        return URL(fileURLWithPath: String(cString: buffer))
    }
    static func paths(program: URL, home: URL, environment: URL, messages: URL) throws -> Paths {
        try Paths(program: physical(program), home: physical(home), environment: physical(environment), messages: physical(messages))
    }
    static func profile(program: URL, home: URL, environment: URL) throws -> String {
        // Use physical paths both in policy AND actual child argv/cwd. Merely changing the policy
        // still denies /var's symlink traversal before the selected file is reached.
        let program = try physical(program), home = try physical(home), environment = try physical(environment)
        func q(_ value: String) -> String { JSONWriter.compact(.str(value)) }
        return """
        (version 1)
        (allow default)
        (deny file-read-data (require-all (require-any (subpath "/Users") (subpath "/Volumes") (subpath "/private/var") (subpath "/var") (subpath "/private/tmp") (subpath "/tmp") (subpath "/opt") (subpath "/Library/Application Support") (subpath "/Library/Keychains")) (require-not (subpath \(q(home.path)))) (require-not (literal \(q(program.path)))) (require-not (literal \(q(environment.path)))) (require-not (subpath "/private/var/db/dyld")) (require-not (subpath "/private/var/db/timezone")) (require-not (subpath "/var/db/timezone")) (require-not (subpath "/opt/homebrew/Cellar")) (require-not (subpath "/usr/local/Cellar")) (require-not (subpath "/opt/homebrew/opt")) (require-not (subpath "/usr/local/opt")) (require-not (literal "/opt/homebrew/etc/openssl@3/cert.pem")) (require-not (literal "/opt/homebrew/etc/ca-certificates/cert.pem")) (require-not (literal "/usr/local/etc/openssl@3/cert.pem")) (require-not (literal "/usr/local/etc/ca-certificates/cert.pem")) (require-not (literal "/Library/Keychains/System.keychain"))))
        (deny mach-lookup (global-name "com.apple.securityd") (global-name "com.apple.securityd.xpc"))
        (deny file-write* (require-all (require-not (subpath \(q(home.path)))) (require-not (subpath "/dev/fd")) (require-not (literal "/dev/null"))))
        (deny process-exec (require-not (literal \(q(program.path)))))
        (deny process-fork)
        """
    }
    static func resident(_ pid: pid_t) -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        return result == 0 ? usage.ri_resident_size : 0
    }
    static func size(_ root: URL) throws -> Int {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey], options: []) else { throw IMAPIntakeImport.Refused.unavailable }
        var size = 0, count = 0
        for case let url as URL in entries {
            count += 1; let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard count <= 4_000, values.isSymbolicLink != true else { throw IMAPIntakeImport.Refused.limit }
            size += values.fileSize ?? 0
            if size > 256 * 1024 * 1024 { return size }
        }
        return size
    }
}
