import Foundation
import NaturalLanguage

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
    /// the helper the file is held, saying the reader is missing.
    public static func read(_ file: URL, attachments: [URL] = [], channel: String, reader: ExtractHelper.Reader) -> IntakeReading {
        let result: Extractor.Result
        do { result = try ExtractHelper.run(file, reader: reader) } catch {
            return IntakeReading(kind: "unknown", textFrom: "parsed", text: "", held: "\(error)", channel: channel)
        }
        var r = IntakeReading(kind: result.email != nil ? "email" : result.kind, textFrom: result.textFrom, pages: result.pages,
                              text: result.text, held: result.problem, channel: result.email != nil ? "email" : channel)
        r.mismatch = result.mismatch
        if let e = result.email {
            r.subject = e.subject; r.from = e.from; r.to = e.to; r.date = e.date
        }
        var parts: [(String, Result<Extractor.Result, Error>)] = []
        for a in result.email?.attachments ?? [] { parts.append((a.name, Result { try ExtractHelper.run(a.data, name: a.name, reader: reader) })) }
        for url in attachments { parts.append((url.lastPathComponent, Result { try ExtractHelper.run(url, reader: reader) })) }
        for (name, outcome) in parts {
            r.attachments.append(name)
            switch outcome {
            case .failure(let error): r.notes.append("attachment \u{201C}\(name)\u{201D} was not read: \(error)")
            case .success(let a):
                if let problem = a.problem { r.notes.append("attachment \u{201C}\(name)\u{201D} was not read: \(problem)"); continue }
                if a.textFrom == "ocr" { r.textFrom = "ocr" }
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
                if let m = text.firstMatch(of: /([+-])(\d{2})(\d{2})$/) {
                    offset = (Int(m.output.2)! * 3600 + Int(m.output.3)! * 60) * (m.output.1 == "-" ? -1 : 1)
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

    init?(json o: JSONValue) {
        guard let kind = o["kind"]?.stringValue, let text = o["text"]?.stringValue else { return nil }
        self.init(kind: kind, textFrom: o["text_from"]?.stringValue ?? "parsed", pages: o["pages"]?.numberValue?.safeInteger.map(Int.init),
                  text: text, held: o["held"]?.stringValue, channel: o["channel"]?.stringValue ?? "other")
        notes = o["notes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        mismatch = o["mismatch"] == .bool(true)
        subject = o["subject"]?.stringValue; from = o["from"]?.stringValue; to = o["to"]?.stringValue; date = o["date"]?.stringValue
        attachments = o["attachments"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

/// Facts code finds in a reading (§4.1 steps 4 and 5): dates, amounts, reference numbers and the words that
/// hint at what the document is. They go on the card and in front of the model; the model never makes them.
public struct IntakeFacts: Sendable, Equatable {
    public var dates: [String] = []
    public var amounts: [String] = []
    public var references: [String] = []
    public var signals: [String] = []
    public var words = 0

    static let signalWords: [String: String] = [
        "invoice": "invoice", "facture": "invoice", "bill": "invoice", "amount due": "payment", "montant dû": "payment",
        "payment": "payment", "paiement": "payment", "due": "deadline", "deadline": "deadline", "échéance": "deadline",
        "notice": "notice", "avis": "notice", "please reply": "reply", "please respond": "reply", "let me know": "reply",
        "veuillez répondre": "reply", "minutes": "minutes", "procès-verbal": "minutes", "bylaw": "governing",
        "by-law": "governing", "règlement": "governing", "declaration": "governing", "déclaration": "governing",
        "amendment": "governing", "contract": "governing", "contrat": "governing", "agreement": "governing", "lease": "governing",
        "bail": "governing", "policy": "governing", "statement": "statement", "relevé": "statement", "receipt": "receipt",
        "reçu": "receipt", "confirmation": "confirmation", "sign": "signature", "signer": "signature", "signature": "signature",
    ]

    public static func of(_ reading: IntakeReading, anchor: CalendarDate, locale: String = "und") -> IntakeFacts {
        var f = IntakeFacts()
        let text = reading.text
        f.words = CaptureText.wordCount(text)
        let lower = text.lowercased()
        for (word, signal) in signalWords.sorted(by: { $0.key < $1.key }) where !f.signals.contains(signal) {
            if lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", options: .regularExpression) != nil { f.signals.append(signal) }
        }
        if text.contains("?"), ["reply"].allSatisfy({ !f.signals.contains($0) }),
           lower.range(of: #"\b(could you|can you|would you|pourriez-vous|pouvez-vous)\b"#, options: .regularExpression) != nil {
            f.signals.append("question")
        }
        for s in CaptureText.sentences(String(text.prefix(200_000))).prefix(2000) {
            // Only written dates count, never "Thursday": a full date, or one whose year is written in the sentence.
            if f.dates.count < 6, let found = DateGrammar.scan(s.text, anchor: anchor, locale: locale), let d = found.date,
               DateGrammar.isFullDate(found.text) || s.text.contains(String(d.year)), !f.dates.contains(d.description) {
                f.dates.append(d.description)
            }
            if f.amounts.count < 6, let a = Amounts.scan(s.text), a.value > 0 {
                let shown = (a.currency.map { $0 + " " } ?? "") + String(format: a.value == a.value.rounded() ? "%.0f" : "%.2f", a.value)
                if !f.amounts.contains(shown) { f.amounts.append(shown) }
            }
            if f.dates.count >= 6 && f.amounts.count >= 6 { break }
        }
        let refPattern = #/(?i)\b(?:invoice|account|file|reference|ref|policy|facture|dossier|compte|numéro|no\.|n°)\s*(?:number|no\.?|#|n°)?\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{3,24})\b/#
        for m in text.prefix(200_000).matches(of: refPattern) where f.references.count < 4 {
            let ref = String(m.output.1)
            guard ref.contains(where: \.isNumber), !f.references.contains(ref) else { continue }
            f.references.append(ref)
        }
        return f
    }

    public var json: JSONValue {
        .obj([("dates", .array(dates.map(JSONValue.string))), ("amounts", .array(amounts.map(JSONValue.string))),
              ("references", .array(references.map(JSONValue.string))), ("signals", .array(signals.map(JSONValue.string))),
              ("words", .int(words))])
    }
}

/// Sprava's own store of intake readings (§4.1 step 2), one file per reading in `capture/readings/`: the text,
/// the binder and card it belongs to, the model's reading once done, and whether a careful reading is wanted
/// (§4.4). The text never goes into a binder or a log.
public struct IntakeReadings: Sendable {
    public let support: URL

    public init(support: URL) { self.support = support }

    var dir: URL { support.appendingPathComponent("capture/readings", isDirectory: true) }

    public struct Entry: Sendable {
        public var id: String
        public var binder: String           // the binder folder's path
        public var name: String             // relative to intake/
        public var sha256: String
        public var card: String             // the filing card this reading belongs to
        public var state: String            // pending, attempt, read, kept, gone
        public var attempts: Int
        public var reading: IntakeReading
        public var createdAt: String
        /// Why a careful reading is recommended; empty when it is not.
        public var escalate: [String]
        public var escalation: String?      // waiting, answered
        public var answer: String?          // the brain's proposal id
        public var result: JSONObject?      // the model's reading: class, title, date, summary, reply_needed

        var json: JSONObject {
            var o = JSONObject([(key: "id", value: .string(id)), (key: "binder", value: .string(binder)), (key: "name", value: .string(name)),
                                (key: "sha256", value: .string(sha256)), (key: "card", value: .string(card)), (key: "state", value: .string(state)),
                                (key: "attempts", value: .int(attempts)), (key: "reading", value: .object(reading.json)),
                                (key: "created_at", value: .string(createdAt))])
            if !escalate.isEmpty { o.set("escalate", .array(escalate.map(JSONValue.string))) }
            if let escalation { o.set("escalation", .string(escalation)) }
            if let answer { o.set("answer", .string(answer)) }
            if let result { o.set("result", .object(result)) }
            return o
        }

        init(id: String, binder: String, name: String, sha256: String, card: String, reading: IntakeReading, now: Date) {
            self.id = id; self.binder = binder; self.name = name; self.sha256 = sha256; self.card = card
            self.state = "pending"; self.attempts = 0; self.reading = reading; self.createdAt = ISOTime.string(now)
            self.escalate = []
        }

        init?(json o: JSONValue) {
            guard let id = o["id"]?.stringValue, let binder = o["binder"]?.stringValue, let name = o["name"]?.stringValue,
                  let sha = o["sha256"]?.stringValue, let card = o["card"]?.stringValue, let r = o["reading"], let reading = IntakeReading(json: r)
            else { return nil }
            self.id = id; self.binder = binder; self.name = name; self.sha256 = sha; self.card = card; self.reading = reading
            state = o["state"]?.stringValue ?? "pending"
            attempts = Int(o["attempts"]?.numberValue?.safeInteger ?? 0)
            createdAt = o["created_at"]?.stringValue ?? ""
            escalate = o["escalate"]?.arrayValue?.compactMap(\.stringValue) ?? []
            escalation = o["escalation"]?.stringValue
            answer = o["answer"]?.stringValue
            result = o["result"]?.objectValue
        }
    }

    func url(_ id: String) -> URL { dir.appendingPathComponent(id + ".json") }

    public func save(_ e: Entry) {
        try? AtomicFile.makePrivateFolder(dir)
        try? AtomicFile.write(Data(JSONWriter.pretty(.object(e.json)).utf8), to: url(e.id))
    }

    public func load(_ id: String) -> Entry? {
        guard id.wholeMatch(of: /[A-Za-z0-9-]{1,80}/) != nil, let data = try? Data(contentsOf: url(id)),
              let v = try? JSONParser.parse(data).value else { return nil }
        return Entry(json: v)
    }

    public func all() -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { load(String($0.dropLast(5))) }
    }

    public func forCard(_ card: String) -> Entry? { all().first { $0.card == card } }

    /// Drops readings that ended more than 60 days ago; a careful reading still waiting is kept.
    public func prune(now: Date) {
        for e in all() where ["read", "kept", "gone"].contains(e.state) && e.escalation != "waiting" {
            if let t = Timestamp.parse(e.createdAt), now.timeIntervalSince(t) > 60 * 86_400 { try? FileManager.default.removeItem(at: url(e.id)) }
        }
    }

    /// The careful readings a connected brain may pick up (§4.4): waiting, in binders it may see (all when nil),
    /// and whose card the person has not rejected.
    public func escalations(in folders: Set<String>? = nil) -> [Entry] {
        var states: [String: [String: String]] = [:]
        return all().filter { e in
            guard e.escalation == "waiting", folders?.contains(e.binder) ?? true else { return false }
            if states[e.binder] == nil { states[e.binder] = Self.cardStates(e.binder) }
            return Self.cardStands(states[e.binder]?[e.card])
        }
    }

    /// One careful reading a brain names by id, under the same rules as `escalations`: waiting, in `binder`, and
    /// its card not rejected. Every lookup by id goes through here, so a remembered id opens nothing more.
    public func escalation(_ id: String, in binder: String) -> Entry? {
        guard let e = load(id), e.binder == binder, e.escalation == "waiting",
              Self.cardStands(Self.cardStates(binder)[e.card]) else { return nil }
        return e
    }

    /// Proposal id -> state, for the cards in one binder.
    static func cardStates(_ binder: String) -> [String: String] {
        Dictionary(ProposalStore.list(in: URL(fileURLWithPath: binder, isDirectory: true)).map { ($0.0.id, $0.0.state) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// A reading is offered while its filing card waits or was approved; never once the person rejected it.
    static func cardStands(_ state: String?) -> Bool { ["proposed", "applied"].contains(state ?? "") }
}
