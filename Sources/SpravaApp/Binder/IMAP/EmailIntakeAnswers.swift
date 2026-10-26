import Foundation
import SpravaKit

/// Reading the runtime's answers, and the sentences the setup shows for them.
extension EmailIntakeModel {
    static func status(_ r: JSONObject) -> Status {
        var s = Status()
        s.installed = r["installed"] != .bool(false); s.enabled = r["enabled"] == .bool(true)
        s.running = r["running"] == .bool(true); s.needsPassword = r["needs_password"] == .bool(true)
        s.host = r["host"]?.stringValue; s.port = int(r["port"]); s.security = r["security"]?.stringValue.flatMap(Security.init(rawValue:))
        s.pin = r["pin"]?.stringValue; s.user = r["user"]?.stringValue
        s.mailbox = r["mailbox"]?.stringValue; s.sender = r["sender"]?.stringValue ?? ""; s.subject = r["subject"]?.stringValue ?? ""
        s.search = r["search"]?.stringValue ?? ""; s.includeExisting = r["include_existing"] != .bool(false)
        s.message = r["message"]?.stringValue
        return s
    }

    static func serverCheck(_ r: JSONObject) -> ServerCheck? {
        guard let host = r["host"]?.stringValue, let security = r["security"]?.stringValue.flatMap(Security.init(rawValue:)),
              let port = int(r["port"]), let result = r["result"]?.stringValue else { return nil }
        let attempts: [(security: Security, port: Int, result: String)] = (r["attempts"]?.arrayValue ?? []).compactMap {
            guard let security = $0["security"]?.stringValue.flatMap(Security.init(rawValue:)), let port = int($0["port"]),
                  let result = $0["result"]?.stringValue else { return nil }
            return (security, port, result)
        }
        return ServerCheck(host: host, security: security, port: port, result: result, fingerprint: r["fingerprint"]?.stringValue,
                           loopback: r["loopback"] == .bool(true), attempts: attempts)
    }

    static func describe(_ check: ServerCheck) -> String {
        let way = "\(check.security.label) on port \(check.port)"
        switch check.result {
        case "ok":
            return check.loopback && check.port == 1143 ? "\(way) answers. This looks like Proton Mail Bridge." : "\(way) answers."
        case "untrusted":
            return check.loopback
                ? "\(way) answers with a self-signed certificate, as bridges on this Mac do. Trust it only if this fingerprint matches the bridge's certificate."
                : "\(check.host) answers on port \(check.port), but its certificate does not verify, so Sprava will not send a password to it."
        case "oauth_only":
            return "\(check.host) accepts only OAuth sign-in (as Microsoft 365 and Google Workspace do), which Sprava does not support yet. Forwarding that mail to an account with password sign-in works."
        case "unknown_host":
            return "No server named \(check.host) was found. Check the spelling."
        default:
            let tried = (check.attempts.isEmpty ? [(check.security, check.port, check.result)] : check.attempts)
                .map { "\($0.0.label) on \($0.1): \(phrase($0.2))" }.joined(separator: "; ")
            return "Nothing usable answered (\(tried)). Pick the security and port your provider lists, then check again."
        }
    }

    /// A SHA-256 fingerprint as people compare it: upper-case byte pairs.
    static func grouped(_ fingerprint: String) -> String {
        let characters = Array(fingerprint.uppercased())
        return stride(from: 0, to: characters.count, by: 2).map { String(characters[$0..<min($0 + 2, characters.count)]) }.joined(separator: ":")
    }

    private static func phrase(_ result: String) -> String {
        switch result {
        case "unreachable": "refused"
        case "no_answer": "no answer"
        case "tls": "TLS failed"
        case "not_imap": "not IMAP"
        default: result
        }
    }

    static func int(_ value: JSONValue?) -> Int? {
        guard let number = value?.numberValue, number.isIntegerLiteral else { return nil }
        return Int(number.text)
    }
}
