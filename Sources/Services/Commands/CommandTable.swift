import BinderFormat
import BinderStore
import Darwin
import Foundation
import SpravaKit

/// The command table: every command the app and the CLI send, by name. Each area keeps its handlers in its own file
/// (`BinderCommands`, `SettingsCommands`; `CaptureCommands`, `BackupCommands` and `BrainCommands` come with their
/// areas); adding a command adds a line to one of them.
extension Commands {
    /// How information reached the person (docs/adaptation-layer.md §3.3).
    public static let channels: Set<String> = ["email", "paper", "download", "message", "note", "other"]

    /// One command's handler: the command's name (approve and reject share one), the request, the time and the day.
    typealias Handler = @Sendable (Commands, _ command: String, _ r: JSONObject, _ now: Date, _ today: CalendarDate) throws -> JSONObject

    static let pingCommand: [String: Handler] = [
        "ping": { _, _, _, _, _ in JSONObject([(key: "protocol", value: .int(1))]) },
    ]

    /// Every command, by name.
    static let table: [String: Handler] = pingCommand
        .merging(binderCommands) { a, _ in a }
        .merging(captureCommands) { a, _ in a }
        .merging(settingsCommands) { a, _ in a }

    /// Handles one request: `{"command": ..., ...}`. Returns `{"ok": true, ...}` or `{"ok": false, "error": ...}`.
    public func handle(_ request: String, now: Date = Date(), today: CalendarDate? = nil) -> String {
        do {
            guard case .object(let r) = try JSONParser.parse(request).value, case .string(let command)? = r["command"] else {
                throw Failure(message: "malformed request")
            }
            let result = try run(command, r, now: now, today: today ?? CalendarDate.today(now: now))
            var reply = JSONObject([(key: "ok", value: .bool(true))])
            for e in result.entries { reply.set(e.key, e.value) }
            return JSONWriter.compact(.object(reply))
        } catch {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .string("\(error)"))]))
        }
    }

    func folder(_ r: JSONObject) throws -> URL {
        guard case .string(let path)? = r["binder"], path.hasPrefix("/") else { throw Failure(message: "binder must be an absolute path") }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// The device the owner record names, read only from a regular file: a link or a FIFO at `.sprava/owner.json`
    /// counts as a damaged record, so the read neither follows it out of the binder nor blocks on it.
    func ownerDevice(_ f: URL) -> String? {
        // SafeFile opens without following a link or blocking on a FIFO, checks a regular file, and bounds the read.
        guard case .ok(let data) = SafeFile.read(f.appendingPathComponent(".sprava/owner.json"), limit: Self.ownerRecordLimit),
              let value = try? JSONParser.parse(data).value else { return nil }
        return value["device"]?.stringValue
    }

    /// An owner record is a few lines; anything larger is damaged.
    static let ownerRecordLimit = 64 * 1024

    func run(_ command: String, _ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // An interrupted expunge (binder-v0 §6.11): the cards and the op log may still hold the text being forgotten,
        // so nothing in the binder is read or changed until the expunge is repeated.
        if Self.binderCommands[command] != nil && command != "create_binder" || command == "binder_settings",
           Teka.expungePending(in: try folder(r)) {
            throw Failure(message: "an expunge in this binder was interrupted; enter the text again to finish it before anything else")
        }
        if ["approve", "reject", "apply", "undo", "switch_dashboard", "file_card", "binder_settings"].contains(command) {
            let f = try folder(r)
            // Fail closed: an adopted binder accepts writes only when its owner record names this Mac.
            let adopted = FileManager.default.fileExists(atPath: f.appendingPathComponent(".sprava/ops.ndjson").path)
            if adopted, case let owner = ownerDevice(f), owner != deviceID {
                throw Failure(message: owner == nil
                    ? "this binder's owner record is missing or damaged; it is read-only until it is repaired"
                    : "this binder is managed by another Sprava (another Mac or a development build); it is read-only here")
            }
        }
        guard let handler = Self.table[command] else { throw Failure(message: "unknown command \(command)") }
        return try handler(self, command, r, now, today)
    }
}
