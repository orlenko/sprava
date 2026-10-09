import BinderStore
import Foundation
import SpravaKit

/// The command table: every command the app and the CLI send, by name. Each area keeps its handlers in its own file
/// (`BinderCommands`, `CaptureCommands`, `BackupCommands`, `BrainCommands`, `SettingsCommands`); adding a command
/// adds a line to one of them.
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
        .merging(backupCommands) { a, _ in a }
        .merging(brainCommands) { a, _ in a }
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

    func run(_ command: String, _ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        if ["approve", "reject", "apply", "undo", "switch_dashboard", "file_card", "binder_settings"].contains(command) {
            let f = try folder(r)
            // Fail closed: an adopted binder accepts writes only when its owner record names this Mac.
            let adopted = FileManager.default.fileExists(atPath: f.appendingPathComponent(".sprava/ops.ndjson").path)
            if adopted, Owner.device(of: f) != deviceID {
                throw Failure(message: Owner.device(of: f) == nil
                    ? "this binder's owner record is missing or damaged; it is read-only until it is repaired"
                    : "this binder is managed by another Sprava (another Mac or a development build); it is read-only here")
            }
        }
        guard let handler = Self.table[command] else { throw Failure(message: "unknown command \(command)") }
        return try handler(self, command, r, now, today)
    }
}
