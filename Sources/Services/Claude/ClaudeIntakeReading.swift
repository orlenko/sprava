import Clerk
import Foundation
import SpravaKit

/// Claude reading an intake document in the clerk's place (decisions.md D40): one tool-free Sonnet call per document,
/// in a binder connected to Claude with intake shared, at most `dailyCalls` a day.
enum ClaudeIntakeReading {
    static let dailyCalls = 100
    /// The most of a reply that is read as an answer; a reading is a few kilobytes.
    static let replyLimit = 256 * 1024

    /// Why a call was not made or not used. Each says only which, never content: it is logged and stored.
    static func refusal(_ why: String) -> ClerkModelError { .unavailable(why) }

    /// The one JSON object of a reply. A model may wrap it in a code fence or a sentence; what lies between its first
    /// `{` and its last `}` is parsed, and anything that is not one safe object is no answer.
    static func answer(_ reply: String) throws -> JSONValue {
        guard reply.utf8.count <= replyLimit, let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let parsed = try? JSONParser.parse(Data(reply[start...end].utf8)), parsed.safety.isSafe, case .object = parsed.value else {
            throw refusal("bad reply")
        }
        return parsed.value
    }

    /// The day's count of calls, in `runtime/intake-readings.json`. A call counts when it is started, whatever its end.
    struct Cap {
        let file: URL
        init(support: URL) { file = support.appendingPathComponent("runtime/intake-readings.json") }

        /// Counts one call for today and says whether it is within the cap. An unreadable count is taken as spent, so a
        /// damaged file never lifts the cap.
        func take(now: Date = Date()) -> Bool {
            let today = CalendarDate.today(now: now).description
            var calls = 0
            switch SafeFile.read(file, limit: 4096) {
            case .ok(let data):
                guard let value = try? JSONParser.parse(data).value else { return false }
                if value["day"]?.stringValue == today {
                    guard let n = value["calls"]?.numberValue?.safeInteger, n >= 0 else { return false }
                    calls = Int(n)
                }
            case .missing: break
            default: return false
            }
            guard calls < dailyCalls else { return false }
            let next = JSONValue.obj([("day", .string(today)), ("calls", .int(calls + 1))])
            do {
                try AtomicFile.makePrivateFolder(file.deletingLastPathComponent())
                try AtomicFile.write(Data(JSONWriter.compact(next).utf8), to: file)
            } catch { return false }
            return true
        }
    }

    /// The engine the clerk is given for one binder. It holds no credential: each call asks the runtime, which checks
    /// the binder's connection again.
    struct Engine: DocumentEngine {
        let name = "Claude"
        let folder: URL
        let runtime: ClaudeConversationRuntime
        func answer(instructions: String, prompt: String) async throws -> JSONValue {
            try await runtime.readIntake(folder: folder, instructions: instructions, prompt: prompt)
        }
    }
}
