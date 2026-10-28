import BinderFormat
import Foundation
import Extract
import SpravaKit

/// The built-in raw-message intake. Its cursor advances only after complete, immutable intake
/// publication. A crash re-fetches from the last committed cursor; it never acknowledges partial mail.
public enum IMAPIntakeImport {
    public enum Refused: Error, Equatable { case invalidCursor, invalidExport, limit, unavailable, authentication, untrusted, needsPassword, partial(Int) }
    public struct Cursor: Codable, Equatable, Sendable {
        let uid_validity: UInt32?
        let last_seen_uid: UInt32
        static func read(_ directory: StateDirectory) throws -> Cursor? {
            switch try directory.read("state.json", limit: 1_024) {
            case .missing: return nil
            case .ok(let data):
                let parsed = try JSONParser.parse(data)
                guard parsed.safety.isSafe, let object = parsed.value.objectValue,
                      Set(object.entries.map(\.key)) == ["uid_validity", "last_seen_uid"],
                      let value = try? JSONDecoder().decode(Cursor.self, from: data) else { throw Refused.invalidCursor }
                return value
            default: throw Refused.invalidCursor
            }
        }
    }
    public typealias Fetch = @Sendable (BinderIMAPConnections.Configuration, URL, URL) throws -> Void

    /// Fetch receives only a private cwd and export directory, never the live intake destination.
    public static func run(_ config: BinderIMAPConnections.Configuration, support: URL,
                           connections: BinderIMAPConnections, fetch: Fetch, reader: ExtractHelper.Reader = .located(),
                           canPublish: @Sendable () throws -> Bool = { true }) throws -> Int {
        let root = support.appendingPathComponent("capture/imap-runs/" + config.id.uuidString)
        guard let home = try StateDirectory.open(root, create: true) else { throw Refused.unavailable }
        let old = try Cursor.read(home)
        guard old?.uid_validity != nil || old == nil else { throw Refused.invalidCursor }
        if old?.last_seen_uid == UInt32.max { throw Refused.limit }
        let name = "batch-" + UUID().uuidString
        guard let batch = try home.directory(name, create: true), let _ = try batch.directory("messages", create: true) else { throw Refused.unavailable }
        let batchURL = root.appendingPathComponent(name)
        // These are disposable remote copies. The server is never marked read or modified; after
        // any failure the canonical cursor still causes a fresh fetch of the unacknowledged range.
        defer { try? FileManager.default.removeItem(at: batchURL) }
        if let old { try batch.write(JSONEncoder().encode(old), to: "state.json") }
        guard try canPublish() else { throw Refused.unavailable }; _ = try connections.current(config)
        var fetchFailure: (any Error)?
        do { try fetch(config, batchURL, batchURL.appendingPathComponent("messages")) } catch { fetchFailure = error }
        guard let current = try Cursor.read(batch), let validity = current.uid_validity else {
            if let fetchFailure { throw fetchFailure }; throw Refused.invalidCursor
        }
        guard try canPublish() else { throw Refused.unavailable }; _ = try connections.current(config)
        if let fetchFailure, current == old, try FileManager.default.contentsOfDirectory(atPath: batchURL.appendingPathComponent("messages").path).isEmpty { throw fetchFailure }
        if old?.uid_validity != validity {
            if let fetchFailure { throw fetchFailure }
            // The app exporter baselines on first connection/UIDVALIDITY change. Commit an
            // explicit zero cursor for Include existing, then fetch history on the following tick.
            guard try FileManager.default.contentsOfDirectory(atPath: batchURL.appendingPathComponent("messages").path).isEmpty else { throw Refused.invalidExport }
            let baseline = Cursor(uid_validity: validity, last_seen_uid: config.includeExisting ? 0 : current.last_seen_uid)
            try home.write(JSONEncoder().encode(baseline), to: "state.json")
            return 0
        }
        guard current.last_seen_uid >= (old?.last_seen_uid ?? 0) else { throw Refused.invalidCursor }
        let count = try publish(config, folder: try connections.current(config), messages: batchURL.appendingPathComponent("messages"),
                                validity: validity, after: old?.last_seen_uid ?? 0, through: current.last_seen_uid, partial: fetchFailure != nil, connections: connections, canPublish: canPublish, reader: reader)
        try home.write(JSONEncoder().encode(current), to: "state.json")
        if fetchFailure != nil { throw Refused.partial(count) }
        return count
    }

    static func publish(_ config: BinderIMAPConnections.Configuration, folder: URL, messages: URL,
                        validity: UInt32, after: UInt32, through: UInt32, partial: Bool, connections: BinderIMAPConnections,
                        canPublish: @Sendable () throws -> Bool, reader: ExtractHelper.Reader) throws -> Int {
        let names = try FileManager.default.contentsOfDirectory(atPath: messages.path).sorted()
        guard names.count <= 64, let staged = try StateDirectory.open(messages), let binder = try StateDirectory.open(folder),
              let intake = try binder.directory("intake", create: true), let mail = try intake.directory("mail", create: true) else { throw Refused.limit }
        var count = 0, bytes = 0
        for name in names {
            guard name.hasPrefix("mail-"), name.hasSuffix(".eml"),
                  let uid = UInt32(name.dropFirst(5).dropLast(4)) else { throw Refused.invalidExport }
            if partial && uid > through { continue }
            guard uid > after, uid <= through, case .ok(let raw) = try staged.read(name, limit: 64 * 1024 * 1024) else { throw Refused.invalidExport }
            if try connections.imported(config.id, validity: validity, uid: uid) != nil { continue }
            bytes += raw.count; guard bytes <= 256 * 1024 * 1024 else { throw Refused.limit }
            // All untrusted MIME parsing stays in the existing sandboxed helper. The original is
            // retained byte-for-byte, even when its bounded parser cannot materialize every part.
            let decoded = try ExtractHelper.run(raw, name: "message.eml", reader: reader, timeout: 30)
            guard decoded.problem == nil, let email = decoded.email else { throw Refused.invalidExport }
            if !config.sender.isEmpty && !(email.from ?? "").localizedCaseInsensitiveContains(config.sender) { continue }
            if !config.subject.isEmpty && !(email.subject ?? "").localizedCaseInsensitiveContains(config.subject) { continue }
            guard try canPublish() else { throw Refused.unavailable }; _ = try connections.current(config)
            let base = "imap-\(config.id.uuidString)-\(validity)-\(uid)"
            var fields = "---\n"
            for (key, value) in [("subject", email.subject), ("from", email.from), ("date", email.date), ("to", email.to)] {
                fields += key + ": " + JSONWriter.compact(.str(String((value ?? "").prefix(4_096)))) + "\n"
            }
            let data = Data((fields + "---\n\n" + decoded.text + "\n\nOriginal email and all MIME parts are retained in the matching attachments folder. This Markdown rendering and attachment extraction are bounded.\n").utf8)
            guard data.count <= 8 * 1024 * 1024 else { throw Refused.limit }
            switch try mail.read(base + ".md", limit: 8 * 1024 * 1024) {
            case .missing: break
            case .ok(let existing) where existing == data: break
            default: throw Refused.invalidExport
            }
            guard let target = try mail.directory(base + " attachments", create: true) else { throw Refused.unavailable }
            try target.createImmutable(raw, to: "000-original-message.eml")
            for (index, attachment) in email.attachments.prefix(128).enumerated() {
                let original = (attachment.name as NSString).lastPathComponent
                // A secret/key attachment remains in the original message, never a renamed
                // ordinary file that the document index could read around its key-file exclusion.
                guard !original.hasPrefix("."), !DocumentPaths.isKeyFile(attachment.name), !DocumentPaths.isKeyFile(original) else { continue }
                var cleaned = String(String.UnicodeScalarView(original.unicodeScalars.filter {
                    !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" && $0 != ":"
                }.prefix(120)))
                while cleaned.utf8.count > 180 { cleaned.removeLast() }
                let file = String(format: "%03d-", index + 1) + (cleaned.isEmpty ? "attachment.bin" : cleaned)
                guard DocumentPaths.isIntake("intake/mail/" + file), attachment.data.count <= 64 * 1024 * 1024 else { throw Refused.invalidExport }
                bytes += attachment.data.count; guard bytes <= 256 * 1024 * 1024 else { throw Refused.limit }
                guard try canPublish() else { throw Refused.unavailable }; _ = try connections.current(config)
                try target.createImmutable(attachment.data, to: file)
            }
            guard try canPublish() else { throw Refused.unavailable }; _ = try connections.current(config)
            try mail.createImmutable(data, to: base + ".md")
            try connections.recordImport(config.id, validity: validity, uid: uid, path: "intake/mail/" + base + ".md")
            count += 1
        }
        return count
    }
}
