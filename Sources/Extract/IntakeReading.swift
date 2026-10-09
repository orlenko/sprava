import BinderFormat
import Foundation
import NaturalLanguage
import SpravaKit

/// What code read from one intake file, or one email message with its attachments (docs/adaptation-layer.md
/// §4.1): the text, how it was obtained, and why the file is held when it cannot be read.
public struct IntakeReading: Sendable, Equatable {
    public var kind: String                 // text, pdf, image, document, email, unknown
    public var textFrom: String             // text-layer, ocr, parsed
    public var pages: Int?
    public var text: String
    /// Set when the file is held for the person instead of read (§4.5).
    public var held: String?
    /// Smaller problems, such as one attachment that could not be read.
    public var notes: [String] = []
    public var mismatch = false
    public var subject: String?
    public var from: String?
    public var to: String?
    public var date: String?
    public var attachments: [String] = []
    /// `email` for a message from a mail monitor or an email file; `other` when the source cannot tell (§3.3).
    public var channel: String

    public init(kind: String, textFrom: String, pages: Int? = nil, text: String, held: String? = nil, channel: String) {
        self.kind = kind; self.textFrom = textFrom; self.pages = pages; self.text = text; self.held = held; self.channel = channel
    }

    /// Reads a file and, for a message, the files of its attachments folder, each in the sandboxed helper. Without
    /// the helper the file is held, saying the reader is missing. A key or credential file (binder-v0 §3.3), alone or
    /// in the attachments folder, is never opened: the whole card is held, and the person can still file it. Every
    /// file is opened from `binder`, the folder the caller trusts, down, never through a link below it.
    public static func read(_ file: URL, in binder: URL, attachments: [URL] = [], channel: String, reader: ExtractHelper.Reader) -> IntakeReading {
        if let key = ([file] + attachments).first(where: { DocumentPaths.isKeyFile($0.lastPathComponent) }) {
            return IntakeReading(kind: "unknown", textFrom: "parsed", text: "",
                                 held: "\u{201C}\(DocumentPaths.safeName(key.lastPathComponent))\u{201D} looks like a key or credential file and is not read",
                                 channel: channel)
        }
        let result: Extractor.Result
        do { result = try ExtractHelper.run(file, under: binder, reader: reader) } catch {
            return IntakeReading(kind: "unknown", textFrom: "parsed", text: "", held: "\(error)", channel: channel)
        }
        var r = IntakeReading(kind: result.email != nil ? "email" : result.kind, textFrom: result.textFrom, pages: result.pages,
                              text: result.text, held: result.problem, channel: result.email != nil ? "email" : channel)
        r.mismatch = result.mismatch
        if let e = result.email {
            r.subject = e.subject; r.from = e.from; r.to = e.to; r.date = e.date
        }
        var parts: [(String, Result<Extractor.Result, Error>)] = []
        for a in result.email?.attachments ?? [] {
            // The helper drops a leading dot from an attachment's name, so `.netrc` arrives as `netrc`.
            if DocumentPaths.isKeyFile(a.name) || DocumentPaths.isKeyFile("." + a.name) {
                r.attachments.append(a.name)
                r.notes.append("attachment \u{201C}\(a.name)\u{201D} looks like a key or credential file and was not read")
                continue
            }
            parts.append((a.name, Result { try ExtractHelper.run(a.data, name: a.name, reader: reader) }))
        }
        for url in attachments { parts.append((url.lastPathComponent, Result { try ExtractHelper.run(url, under: binder, reader: reader) })) }
        for (name, outcome) in parts {
            r.attachments.append(name)
            switch outcome {
            case .failure(let error): r.notes.append("attachment \u{201C}\(name)\u{201D} was not read: \(error)")
            case .success(let a):
                if let problem = a.problem { r.notes.append("attachment \u{201C}\(name)\u{201D} was not read: \(problem)"); continue }
                if a.textFrom == "ocr" { r.textFrom = "ocr" }
                // A forwarded message's own attachments are not read here; a note says so, never silence.
                if let nested = a.email?.attachments, !nested.isEmpty { r.notes.append("attachment \u{201C}\(name)\u{201D} has \(nested.count) attachment(s) of its own that were not read") }
                if !a.text.isEmpty { r.text += "\n\n\u{2014} Attachment: \(name) \u{2014}\n" + a.text }
            }
        }
        if r.held == nil, r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            r.notes.append(r.kind == "image" ? "no text found in the picture" : "no text found")
        }
        return r
    }

    /// The language of the text, as a tag the clerk's date grammar knows (`fr`, `en`), else `und`.
    public static func language(of text: String) -> String {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.english, .french]
        r.processString(String(text.prefix(4000)))
        guard let best = r.languageHypotheses(withMaximum: 1).first, best.value > 0.6 else { return "und" }
        return best.key == .french ? "fr" : "en"
    }

    /// The header date of a message, as a calendar day, in the formats mail programs write.
    public static func day(ofHeader raw: String?) -> CalendarDate? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]).trimmingCharacters(in: .whitespaces) }
        if let d = CalendarDate.strict(String(text.prefix(10))), text.count == 10 || text.dropFirst(10).first.map({ $0 == "T" || $0 == " " }) == true {
            return d
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = format
            if let date = f.date(from: text) {
                // The day as the sender wrote it, in the sender's own offset.
                var offset = 0
                // ASCII digits only, converted checked: a header is untrusted text.
                if let m = text.firstMatch(of: /([+-])([0-9]{2})([0-9]{2})$/), let h = Int(m.output.2), let mi = Int(m.output.3) {
                    offset = (h * 3600 + mi * 60) * (m.output.1 == "-" ? -1 : 1)
                }
                return CalendarDate(date, in: TimeZone(secondsFromGMT: offset) ?? .gmt)
            }
        }
        return nil
    }

    public var json: JSONObject {
        var o = JSONObject()
        o.set("kind", .string(kind))
        o.set("text_from", .string(textFrom))
        if let pages { o.set("pages", .int(pages)) }
        o.set("text", .string(text))
        if let held { o.set("held", .string(held)) }
        if !notes.isEmpty { o.set("notes", .array(notes.map(JSONValue.string))) }
        if mismatch { o.set("mismatch", .bool(true)) }
        for (k, v) in [("subject", subject), ("from", from), ("to", to), ("date", date)] { if let v { o.set(k, .string(v)) } }
        if !attachments.isEmpty { o.set("attachments", .array(attachments.map(JSONValue.string))) }
        o.set("channel", .string(channel))
        return o
    }

    package init?(json o: JSONValue) {
        guard let kind = o["kind"]?.stringValue, let text = o["text"]?.stringValue else { return nil }
        self.init(kind: kind, textFrom: o["text_from"]?.stringValue ?? "parsed", pages: o["pages"]?.numberValue?.safeInteger.map(Int.init),
                  text: text, held: o["held"]?.stringValue, channel: o["channel"]?.stringValue ?? "other")
        notes = o["notes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        mismatch = o["mismatch"] == .bool(true)
        subject = o["subject"]?.stringValue; from = o["from"]?.stringValue; to = o["to"]?.stringValue; date = o["date"]?.stringValue
        attachments = o["attachments"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}
