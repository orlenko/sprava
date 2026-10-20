import Darwin
import Foundation
import SpravaKit

/// The one safe reader of a binder's conversation history, `.sprava/conversation/<YYYY-MM>.ndjson` (binder-v0
/// §7.2.1). It enforces the storage bounds before allocating or parsing what they bound, and reports damaged
/// history instead of joining, repairing or acting on it. It never writes. Everything it returns is display-only:
/// a well-formed message is not an authenticated one.
public enum ConversationHistory {
    /// A month as read: its well-formed messages in file order, and the damaged lines left as they are for repair.
    public struct Month: Sendable, Equatable {
        public let month: String
        public let messages: [ConversationMessage]
        public let damage: [Damage]
    }

    /// Physical lines (one-based) that are not part of a well-formed message.
    public struct Damage: Sendable, Equatable {
        public enum Reason: String, Sendable {
            /// The last line has no final LF.
            case torn
            /// Not one strict JSON object of the line format, or longer than 512 KiB.
            case invalidRecord
            /// A part is missing, out of order, or a group was interrupted by another message.
            case missingPart
            /// A part number came again.
            case duplicatePart
            /// The parts of one message disagree on a member other than their text.
            case mixedMetadata
            /// A message id that an earlier message in this month already used.
            case reusedID
            /// The joined text would be larger than 4 MiB.
            case tooLarge
            /// The message's timestamp names another month.
            case wrongMonth
        }
        public let lines: ClosedRange<Int>
        public let reason: Reason
    }

    public enum Outcome: Sendable, Equatable {
        case month(Month)
        /// The file may not be read at all: a link, not a plain file, another owner, over 64 MiB or 200,000 lines.
        /// It is refused as a whole and left as it is.
        case refused(String)
        /// It could not be read just now.
        case unreadable(String)
    }

    /// The months with a history file, oldest first, or why the folder may not be listed.
    public enum Listing: Sendable, Equatable {
        case months([String])
        case refused(String)
    }

    /// At most this many folder entries are read, so a folder filled with junk cannot exhaust memory or stall a page.
    static let maxEntries = 4096

    /// Lists the history folder one entry at a time, opened without following a link. A name that is not
    /// `YYYY-MM.ndjson` is not history; a folder with more than 4,096 entries is refused, not listed in part.
    public static func months(in binder: URL) -> Listing {
        guard isRealFolder(binder.appendingPathComponent(".sprava")) else { return .months([]) }
        let fd = open(folder(of: binder).path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .months([]) : .refused("the conversation folder cannot be opened") }
        guard let dir = fdopendir(fd) else { close(fd); return .refused("the conversation folder cannot be opened") }
        defer { closedir(dir) }
        var months: [String] = [], seen = 0
        while let entry = readdir(dir) {
            seen += 1
            guard seen <= maxEntries + 2 else { return .refused("the conversation folder holds more than 4,096 entries") }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name.hasSuffix(".ndjson") else { continue }
            let month = String(name.dropLast(".ndjson".count))
            if isMonth(month) { months.append(month) }
        }
        return .months(months.sorted())
    }

    /// Reads one month. A missing file is an empty month.
    public static func read(month: String, in binder: URL) -> Outcome {
        guard isMonth(month) else { return .refused("not a month") }
        for url in [binder.appendingPathComponent(".sprava"), folder(of: binder)] {
            var st = stat()
            if lstat(url.path, &st) != 0 {
                if errno == ENOENT { return .month(Month(month: month, messages: [], damage: [])) }
                return .unreadable(String(cString: strerror(errno)))
            }
            guard st.st_mode & S_IFMT == S_IFDIR else { return .refused("\(url.lastPathComponent) is not a folder") }
        }
        switch SafeFile.read(folder(of: binder).appendingPathComponent("\(month).ndjson"), limit: ConversationLimits.monthFileBytes) {
        case .missing: return .month(Month(month: month, messages: [], damage: []))
        case .refused(let why): return .refused(why)
        case .unreadable(let why): return .unreadable(why)
        case .ok(let data): return read(data, month: month)
        }
    }

    /// Reads a month file's bytes, already within the file size bound.
    static func read(_ data: Data, month: String) -> Outcome {
        guard data.count <= ConversationLimits.monthFileBytes else { return .refused("larger than 64 MiB") }
        let bytes = [UInt8](data)
        let lineCount = bytes.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } + (bytes.last.map { $0 == 0x0A ? 0 : 1 } ?? 0)
        guard lineCount <= ConversationLimits.monthLines else { return .refused("more than 200,000 lines") }

        var grouper = Grouper(month: month)
        var start = 0, number = 0
        while start < bytes.count {
            number += 1
            let end = bytes[start...].firstIndex(of: 0x0A)
            let line = bytes[start..<(end ?? bytes.count)]
            start = (end ?? bytes.count) + 1
            guard end != nil else { grouper.interrupt(); grouper.damage(number...number, .torn); break }
            guard line.count <= ConversationLimits.lineBytes, let part = Part(Data(line)) else {
                grouper.interrupt()
                grouper.damage(number...number, .invalidRecord)
                continue
            }
            grouper.add(part, line: number)
        }
        grouper.interrupt()
        return .month(Month(month: month, messages: grouper.messages, damage: grouper.found.sorted { $0.lines.lowerBound < $1.lines.lowerBound }))
    }

    /// How much of a month file a writer may append after (binder-v0 §7.2.1, as §6.9 does for the op log): its
    /// complete lines, minus a last message whose parts stop before their count. What follows is a crash's torn
    /// group, which the writer sets aside before cutting. A damaged line that is complete stays where it is.
    package static func intactLength(of data: Data) -> Int {
        let bytes = [UInt8](data)
        let end = bytes.last == 0x0A ? bytes.count : (bytes.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0)
        var lineEnd = end, expected: (id: String, part: Int)?
        while lineEnd > 0 {
            let lineStart = bytes[..<(lineEnd - 1)].lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            guard lineEnd - 1 - lineStart <= ConversationLimits.lineBytes,
                  let part = Part(Data(bytes[lineStart..<(lineEnd - 1)])) else { return end }
            if let expected {
                guard part.message.id == expected.id, part.part == expected.part else { return end }
            } else if part.part == part.parts {
                return end
            }
            if part.part == 1 { return lineStart }
            expected = (part.message.id, part.part - 1)
            lineEnd = lineStart
        }
        return end
    }

    static func folder(of binder: URL) -> URL {
        binder.appendingPathComponent(".sprava/conversation", isDirectory: true)
    }

    static func isMonth(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 7, b[4] == 0x2D, b.enumerated().allSatisfy({ $0.offset == 4 || ($0.element >= 0x30 && $0.element <= 0x39) }),
              let month = Int(String(decoding: b[5...], as: UTF8.self)) else { return false }
        return (1...12).contains(month)
    }

    static func isRealFolder(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    // MARK: - Lines and groups

    /// One physical line of the format, its members checked; its text is one part of a message.
    struct Part {
        let message: ConversationMessage
        let part: Int
        let parts: Int
        /// Every member but `text`, `part` and `parts`, as written: the parts of one message must agree on it.
        let header: JSONObject

        init?(_ line: Data) {
            guard let parsed = try? JSONParser.parse(line), parsed.safety.isSafe, case .object(let object) = parsed.value,
                  object["format_version"]?.stringValue == "0",
                  let part = object["part"]?.numberValue?.safeInteger, let parts = object["parts"]?.numberValue?.safeInteger,
                  (1...Int64(ConversationLimits.parts)).contains(parts), (1...parts).contains(part),
                  case .string(let text)? = object["text"], text.utf8.count <= ConversationLimits.partTextBytes,
                  let id = object["id"]?.stringValue, let turn = object["turn"]?.stringValue, let at = object["at"]?.stringValue,
                  let speaker = object["speaker"]?.stringValue.flatMap(ConversationMessage.Speaker.init(rawValue:)),
                  let origin = object["origin"]?.stringValue.flatMap(ConversationMessage.Origin.init(rawValue:)),
                  let list = object["references"]?.arrayValue, list.count <= ConversationLimits.references else { return nil }
            var references: [ConversationMessage.Reference] = []
            for value in list {
                guard case .object(let r) = value, let kind = r["kind"]?.stringValue.flatMap(ConversationMessage.Reference.Kind.init(rawValue:)),
                      let rid = r["id"],
                      let reference = try? ConversationMessage.Reference(kind: kind, id: rid, extra: JSONObject(r.entries.filter { $0.key != "kind" && $0.key != "id" }))
                else { return nil }
                references.append(reference)
            }
            var strings: [String: String] = [:]
            for key in ["device", "model", "request_id"] {
                guard let value = object[key] else { continue }
                guard let string = value.stringValue else { return nil }
                strings[key] = string
            }
            let known: Set<String> = ["format_version", "id", "turn", "at", "speaker", "origin", "text", "part", "parts",
                                      "references", "device", "model", "request_id"]
            guard let message = try? ConversationMessage(id: id, turn: turn, at: at, speaker: speaker, origin: origin, text: text,
                                                         references: references, device: strings["device"],
                                                         model: strings["model"], requestID: strings["request_id"],
                                                         extra: JSONObject(object.entries.filter { !known.contains($0.key) }))
            else { return nil }
            self.message = message
            self.part = Int(part)
            self.parts = Int(parts)
            self.header = JSONObject(object.entries.filter { !["text", "part", "parts"].contains($0.key) })
        }
    }

    /// Joins consecutive parts into messages. A message's parts are written together, so anything between them
    /// interrupts the group, and an interrupted group is damaged, never joined from what is left.
    struct Grouper {
        let month: String
        var messages: [ConversationMessage] = []
        var found: [Damage] = []
        var seen: Set<String> = []
        var open: (first: Int, parts: [Part])?

        init(month: String) { self.month = month }

        mutating func damage(_ lines: ClosedRange<Int>, _ reason: Damage.Reason) {
            found.append(Damage(lines: lines, reason: reason))
        }

        /// An incomplete open group is damaged.
        mutating func interrupt() {
            guard let group = open else { return }
            damage(group.first...(group.first + group.parts.count - 1), .missingPart)
            open = nil
        }

        mutating func add(_ part: Part, line: Int) {
            if let group = open, group.parts[0].message.id == part.message.id {
                let first = group.parts[0]
                let reason: Damage.Reason? = part.part <= group.parts.count ? .duplicatePart
                    : part.header != first.header || part.parts != first.parts ? .mixedMetadata
                    : part.part != group.parts.count + 1 ? .missingPart : nil
                if let reason {
                    damage(group.first...line, reason)
                    open = nil
                    return
                }
                open?.parts.append(part)
            } else {
                interrupt()
                guard !seen.contains(part.message.id) else { damage(line...line, .reusedID); return }
                seen.insert(part.message.id)
                guard part.part == 1 else { damage(line...line, .missingPart); return }
                open = (line, [part])
            }
            guard let group = open, group.parts.count == group.parts[0].parts else { return }
            open = nil
            finish(group.parts, lines: group.first...line)
        }

        /// The count, numbering and metadata are already checked; the size is checked before the text is joined.
        mutating func finish(_ parts: [Part], lines: ClosedRange<Int>) {
            let first = parts[0].message
            guard parts.reduce(0, { $0 + $1.message.text.utf8.count }) <= ConversationLimits.messageTextBytes else {
                damage(lines, .tooLarge)
                return
            }
            guard first.month == month else { damage(lines, .wrongMonth); return }
            var text = ""
            for part in parts { text.unicodeScalars.append(contentsOf: part.message.text.unicodeScalars) }
            guard let message = try? ConversationMessage(id: first.id, turn: first.turn, at: first.at, speaker: first.speaker,
                                                         origin: first.origin, text: text, references: first.references,
                                                         device: first.device, model: first.model, requestID: first.requestID,
                                                         extra: first.extra)
            else { damage(lines, .invalidRecord); return }
            messages.append(message)
        }
    }
}
