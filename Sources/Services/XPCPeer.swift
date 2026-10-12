import Darwin
import Foundation
import Security

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
/// replace the runtime too). The bundle is signed with the hardened runtime, so injected libraries and `DYLD_`
/// variables do not load into the genuine app. Such a program can also write binders on disk directly; the check
/// guards the runtime's own powers (approvals, disclosure, client registration), not the files. A Developer ID
/// release replaces the cdhash pin with `anchor apple generic` and the team's certificate (spike a, architecture 13).
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

