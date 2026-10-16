import Foundation
import SpravaKit

/// One message of a binder's conversation (binder-v0 §7.2.1). A message read from a binder is display-only: its
/// fields describe, they never prove. Only trusted state outside the binder can authenticate one, which this type
/// cannot do, and none of its references is an instruction to open, fetch, apply or undo anything.
public struct ConversationMessage: Sendable, Equatable {
    public enum Speaker: String, Sendable { case person, frontDesk = "front-desk", backOffice = "back-office" }
    public enum Origin: String, Sendable { case app, runtime, terminal }

    /// A typed reference (binder-v0 §7.2.1). A document's `id` keeps the catalog id's JSON type, so integer `7` and
    /// string `"7"` differ; every other kind carries an opaque string.
    public struct Reference: Sendable, Equatable {
        public enum Kind: String, Sendable { case document, capture, op, batch, question, answer, task }
        public let kind: Kind
        public let id: JSONValue
        /// Members this implementation does not know, kept as found.
        public let extra: JSONObject

        public init(kind: Kind, id: JSONValue, extra: JSONObject = JSONObject()) throws {
            switch id {
            case .string(let s) where (1...ConversationLimits.fieldScalars).contains(s.unicodeScalars.count): break
            case .number(let n) where kind == .document && n.safeInteger.map({ $0 != 0 }) == true: break
            default: throw ConversationMessage.Invalid(reason: "a \(kind.rawValue) reference has an id of the wrong kind")
            }
            self.kind = kind
            self.id = id
            self.extra = extra
        }
    }

    /// Why a message cannot be stored or a line read. It never quotes the message's text.
    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
    }

    public let id: String
    public let turn: String
    public let at: String
    public let speaker: Speaker
    public let origin: Origin
    /// The original text, exactly as written: never trimmed, normalized or cut.
    public let text: String
    public let references: [Reference]
    public let device: String?
    public let model: String?
    public let requestID: String?
    /// Top-level members this implementation does not know, kept as found.
    public let extra: JSONObject

    public init(id: String, turn: String, at: String, speaker: Speaker, origin: Origin, text: String,
                references: [Reference] = [], device: String? = nil, model: String? = nil, requestID: String? = nil,
                extra: JSONObject = JSONObject()) throws {
        guard Self.isUUID(id, version7: true) else { throw Invalid(reason: "a message id must be a lowercase UUIDv7") }
        guard Self.isUUID(turn) else { throw Invalid(reason: "a turn must be a lowercase UUID") }
        guard Self.isTimestamp(at) else { throw Invalid(reason: "a message needs a real UTC time, YYYY-MM-DDTHH:MM:SSZ") }
        guard references.count <= ConversationLimits.references else { throw Invalid(reason: "a message holds at most 64 references") }
        guard text.utf8.count <= ConversationLimits.messageTextBytes else { throw Invalid(reason: "a message holds at most 4 MiB of text") }
        for (name, value) in [("device", device), ("model", model)] {
            if let value, !(1...ConversationLimits.fieldScalars).contains(value.unicodeScalars.count) {
                throw Invalid(reason: "a message's \(name) must be 1 to 1,024 characters")
            }
        }
        if speaker == .person {
            guard device != nil else { throw Invalid(reason: "a person's message needs a device") }
            if origin == .app, requestID == nil { throw Invalid(reason: "a person's app message needs its request id") }
        } else {
            guard model != nil else { throw Invalid(reason: "a model's message needs its model identifier") }
        }
        if let requestID, !Self.isUUID(requestID) { throw Invalid(reason: "a request id must be a lowercase UUID") }
        let known = Set(["format_version", "id", "turn", "at", "speaker", "origin", "text", "part", "parts", "references",
                         "device", "model", "request_id"])
        guard !extra.keys.contains(where: known.contains) else { throw Invalid(reason: "an unknown member repeats a known one") }
        self.id = id
        self.turn = turn
        self.at = at
        self.speaker = speaker
        self.origin = origin
        self.text = text
        self.references = references
        self.device = device
        self.model = model
        self.requestID = requestID
        self.extra = extra
    }

    /// The month file the message belongs in, `YYYY-MM`, from its UTC timestamp.
    public var month: String { String(at.prefix(7)) }

    // MARK: - Writing

    /// The physical lines of the message, each a compact JSON object and an LF (binder-v0 §7.2.1): the text split at
    /// Unicode scalar boundaries into at most 64 consecutive parts, each at most 64 KiB of decoded text and each
    /// line at most 512 KiB, with every other member the same on every part. Throws when the message cannot be
    /// stored whole; it never returns a prefix.
    public func lines() throws -> [Data] {
        let overhead = Self.encode(header(), text: "", part: 64, parts: 64).utf8.count + 1
        let budget = ConversationLimits.lineBytes - overhead
        guard budget >= 6 else { throw Invalid(reason: "a message's references and fields leave no room for its text") }
        var parts: [String.UnicodeScalarView] = [String.UnicodeScalarView()]
        var decoded = 0, encoded = 0
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count, cost = Self.encodedCost(of: scalar)
            if decoded + size > ConversationLimits.partTextBytes || encoded + cost > budget {
                parts.append(String.UnicodeScalarView())
                decoded = 0
                encoded = 0
            }
            parts[parts.count - 1].append(scalar)
            decoded += size
            encoded += cost
        }
        guard parts.count <= ConversationLimits.parts else { throw Invalid(reason: "a message is too long to store in 64 parts") }
        let header = header()
        return parts.enumerated().map { index, scalars in
            Data((Self.encode(header, text: String(scalars), part: index + 1, parts: parts.count) + "\n").utf8)
        }
    }

    /// Every member but `text`, `part` and `parts`, in the order the writer uses; parts of one message share it.
    func header() -> JSONObject {
        var entries: [(key: String, value: JSONValue)] = [
            ("format_version", .string("0")), ("id", .string(id)), ("turn", .string(turn)), ("at", .string(at)),
            ("speaker", .string(speaker.rawValue)), ("origin", .string(origin.rawValue)),
        ]
        if let device { entries.append(("device", .string(device))) }
        if let model { entries.append(("model", .string(model))) }
        if let requestID { entries.append(("request_id", .string(requestID))) }
        entries.append(("references", .array(references.map { reference in
            .object(JSONObject([("kind", .string(reference.kind.rawValue)), ("id", reference.id)] + reference.extra.entries))
        })))
        return JSONObject(entries + extra.entries)
    }

    static func encode(_ header: JSONObject, text: String, part: Int, parts: Int) -> String {
        var entries = header.entries
        let at = entries.firstIndex(where: { $0.key == "references" }) ?? entries.count
        entries.insert(contentsOf: [("text", .string(text)), ("part", .number(JSONNumber(text: String(part)))),
                                    ("parts", .number(JSONNumber(text: String(parts))))], at: at)
        return JSONWriter.compact(.object(JSONObject(entries)))
    }

    /// The bytes `JSONWriter` spends on one scalar inside a string.
    static func encodedCost(of scalar: Unicode.Scalar) -> Int {
        switch scalar {
        case "\"", "\\", "\u{08}", "\u{09}", "\u{0A}", "\u{0C}", "\u{0D}": 2
        default: scalar.value < 0x20 ? 6 : String(scalar).utf8.count
        }
    }

    // MARK: - Field rules

    static func isUUID(_ s: String, version7: Bool = false) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count == 36 else { return false }
        for (i, b) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(i) { guard b == UInt8(ascii: "-") else { return false }; continue }
            guard (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) else { return false }
        }
        if version7, bytes[14] != UInt8(ascii: "7") { return false }
        return [UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b")].contains(bytes[19])
    }

    /// `YYYY-MM-DDTHH:MM:SSZ` naming a moment that exists: no 30 February, no hour 24.
    static func isTimestamp(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count == 20, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54, bytes[13] == 0x3A,
              bytes[16] == 0x3A, bytes[19] == 0x5A else { return false }
        func number(_ range: Range<Int>) -> Int? {
            guard bytes[range].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            return Int(String(decoding: bytes[range], as: UTF8.self))
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }
}

/// The storage bounds of binder-v0 §7.2.1, enforced by the one reader and by the writer before it appends.
public enum ConversationLimits {
    public static let partTextBytes = 65_536
    public static let parts = 64
    public static let messageTextBytes = 4_194_304
    public static let lineBytes = 512 * 1024
    public static let monthFileBytes = 64 * 1024 * 1024
    public static let monthLines = 200_000
    public static let references = 64
    static let fieldScalars = 1024
}
