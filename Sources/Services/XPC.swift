import Darwin
import Foundation
import Security
import SpravaKit

/// The app ⇄ runtime protocol (architecture 2.1): one method carrying a JSON request and a JSON reply, so the
/// interface is versioned by the request's content and the same `Commands` code is tested in-process.
@objc public protocol SpravaRuntimeXPC {
    func handle(_ request: String, reply: @escaping (String) -> Void)
}

public enum XPCNames {
    public static let runtime = "ca.orlenko.sprava.runtime.xpc"
    /// The app's signing identifier. Alone it proves nothing: any same-user program can be signed ad hoc under it.
    /// `XPCPeer` pins the app's exact code as well.
    public static let appIdentifier = "ca.orlenko.sprava"
}

/// Who may connect to the runtime (architecture 2.1). The app is signed ad hoc, with no Team ID, so a requirement
/// naming a team is impossible for now. What is checked instead, on every connection:
///
/// - The system checks each message against a code-signing requirement on the peer's audit token (not its pid):
///   the app's identifier and the cdhash of the `SpravaApp` this runtime ships with, read from the signature on disk
///   in the runtime's own bundle when the connection arrives (so an app updated with its bundle is admitted).
/// - The peer runs as the same user, from that bundle's executable path.
///
/// This stops a program that merely signs itself as `ca.orlenko.sprava`, a copy of the app from another build, and
/// an app at another path. It does not stop a program running as the same user that can rewrite the bundle (it can
/// replace the runtime too), or that injects code into the genuine app: the build has no hardened runtime, so for
/// example `DYLD_INSERT_LIBRARIES` still loads into it. Such a program can also write binders on disk directly; the
/// check guards the runtime's own powers (approvals, disclosure, client registration), not the files. A Developer
/// ID release replaces the cdhash pin with `anchor apple generic` and the team's certificate, built with the
/// hardened runtime (spike a, architecture 13).
public enum XPCPeer {
    public struct Unverifiable: Error, CustomStringConvertible {
        public let reason: String
        public var description: String { "the app's signature cannot be verified: \(reason)" }
    }

    /// The app as signed on disk.
    public struct App: Sendable, Equatable {
        public let identifier: String
        /// Lowercase hex.
        public let cdhash: String
        public let executable: URL
    }

    /// The app at `bundle` (a bundle or a single executable): its signature must be valid for the files there now
    /// and name `identifier`.
    public static func app(at bundle: URL, identifier: String = XPCNames.appIdentifier) throws -> App {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw Unverifiable(reason: "no code at the bundle's path")
        }
        let valid = SecStaticCodeCheckValidity(code, [], nil)
        guard valid == errSecSuccess else { throw Unverifiable(reason: "signature invalid (\(valid))") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as NSDictionary? else { throw Unverifiable(reason: "no signing information") }
        guard let signed = dict[kSecCodeInfoIdentifier as String] as? String, signed == identifier else {
            throw Unverifiable(reason: "signed under another identifier")
        }
        guard let unique = dict[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty,
              let executable = dict[kSecCodeInfoMainExecutable as String] as? URL else { throw Unverifiable(reason: "no cdhash") }
        return App(identifier: signed, cdhash: unique.map { String(format: "%02x", $0) }.joined(), executable: executable)
    }

    /// The requirement the system checks every message against.
    public static func requirement(for app: App) -> String {
        "identifier \"\(app.identifier)\" and cdhash H\"\(app.cdhash)\""
    }

    /// The connect-time check besides the requirement: the same user, running the app's own executable.
    public static func accepts(peerUID: uid_t, peerPath: String?, app: App) -> Bool {
        guard peerUID == getuid(), let peerPath else { return false }
        return URL(fileURLWithPath: peerPath).resolvingSymlinksInPath().path == app.executable.resolvingSymlinksInPath().path
    }

    /// A process's executable path, or nil once it has gone.
    public static func path(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer[0..<Int(n)], as: UTF8.self)
    }
}

/// Where an app request runs (architecture 2.1, 3.4). Binder commands run one at a time on the command queue, the
/// single writer, which the MCP listener and the capture and intake jobs share. Backup repository work (restic:
/// peek, setup, the second copy; and the status, which walks the mirror to see what is still waiting for iCloud)
/// runs on a serial queue of its own, so a slow or stalled cloud folder never holds up approvals, MCP calls or
/// captures; it touches no binder. Each request is registered with the watchdog while it
/// runs, so one that hangs is named, and past twice its budget and ten minutes ends the process for launchd to restart.
public final class RequestQueues: @unchecked Sendable {
    public static let repositoryCommands: Set<String> = ["peek", "backup_setup", "backup_second", "backup_status"]
    /// The watchdog's keys and budgets: the app's longest timeout for each kind (15 seconds for a write; ten minutes
    /// for a peek).
    public static let budgets: [String: Duration] = ["app_request": .seconds(15), "app_backup_request": .seconds(600)]

    public let commands = DispatchQueue(label: "sprava.runtime.commands")
    public let repository = DispatchQueue(label: "sprava.runtime.backup-requests")
    let watch: WatchBox?

    public init(watch: WatchBox?) { self.watch = watch }

    /// The request's command name, or "?".
    public static func command(of request: String) -> String {
        (try? JSONParser.parse(request).value["command"]?.stringValue) ?? "?"
    }

    /// Runs `handle` on the request's queue and passes its answer to `reply`, with the command's name and how long it
    /// took in milliseconds.
    public func submit(_ request: String, handle: @escaping @Sendable (String) -> String,
                       reply: @escaping @Sendable (_ answer: String, _ command: String, _ ms: Int) -> Void) {
        let command = Self.command(of: request)
        let repositoryWork = Self.repositoryCommands.contains(command)
        let key = repositoryWork ? "app_backup_request" : "app_request"
        let watch = self.watch
        (repositoryWork ? repository : commands).async {
            let started = Date()
            watch?.started(key)
            let answer = handle(request)
            watch?.finished(key)
            reply(answer, command, Int(Date().timeIntervalSince(started) * 1000))
        }
    }
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
