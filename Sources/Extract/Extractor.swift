import Foundation

/// The type adapters' extraction steps (docs/adaptation-layer.md §4.1, §5). Pure: bytes in, text and facts out.
/// The runtime runs them in the sandboxed `sprava-extract` helper, which has no file and no network access; the
/// bytes arrive on standard input.
public enum Extractor {
    public struct Result: Sendable, Equatable {
        public var kind: String              // text, pdf, image, document, email
        public var text: String
        public var textFrom: String          // entered, text-layer, ocr, parsed
        public var pages: Int?
        public var email: Email?
        public var problem: String?          // set when the file is held for the person
        public var mismatch: Bool = false    // the name says one type, the bytes another

        public init(kind: String, text: String, textFrom: String, pages: Int? = nil, email: Email? = nil, problem: String? = nil) {
            self.kind = kind; self.text = text; self.textFrom = textFrom; self.pages = pages; self.email = email; self.problem = problem
        }
    }

    public struct Email: Sendable, Equatable {
        public var subject: String?
        public var from: String?
        public var to: String?
        public var date: String?
        public var messageID: String?
        public var attachments: [Attachment]
        public struct Attachment: Sendable, Equatable {
            public var name: String
            public var data: Data
        }
    }

    public struct Limits: Sendable {
        public var bytes = 200 * 1024 * 1024
        public var pages = 2000
        public var textChars = 5_000_000
        public init() {}
    }

    // MARK: - Sniffing (by the bytes, never the name)

    public enum Sniffed: String, Sendable { case pdf, png, jpeg, heic, tiff, zip, rtf, html, eml, markdownEmail, text, ole, unknown }

    public static func sniff(_ data: Data, name: String) -> Sniffed {
        let head = [UInt8](data.prefix(16))
        func starts(_ bytes: [UInt8]) -> Bool { head.count >= bytes.count && Array(head.prefix(bytes.count)) == bytes }
        if starts([0x25, 0x50, 0x44, 0x46]) { return .pdf }                         // %PDF
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if head.count >= 12, Array(head[4..<8]) == Array("ftyp".utf8),
           ["heic", "heix", "mif1", "msf1", "heim", "heis"].contains(String(decoding: head[8..<12], as: UTF8.self)) { return .heic }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return .zip }                         // docx, xlsx, pptx, odt, pages...
        if starts([0xD0, 0xCF, 0x11, 0xE0]) { return .ole }                         // old .doc, .xls, .msg
        if starts(Array("{\\rtf".utf8)) { return .rtf }
        guard let text = String(data: data.prefix(64 * 1024), encoding: .utf8) ?? String(data: data.prefix(64 * 1024), encoding: .isoLatin1) else { return .unknown }
        let lower = text.lowercased()
        if text.hasPrefix("---\n"), lower.contains("\nsubject:"), lower.contains("\nfrom:") { return .markdownEmail }
        if isMessage(lower) { return .eml }
        if lower.contains("<html") || lower.contains("<!doctype html") { return .html }
        if data.prefix(4096).contains(0) { return .unknown }
        return .text
    }

    /// Whether text starts as a mail message: a header block of fields only, ending at the first empty line, with
    /// a field only mail carries. Any field may come first and none is required, so a message without a subject, or
    /// one that opens with a signature header, is still read as a message.
    static func isMessage(_ lower: String) -> Bool {
        let block = lower.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").first ?? ""
        var fields = Set<String>()
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" { if fields.isEmpty { return false }; continue }
            // A field name is printable ASCII other than the colon (RFC 5322 section 2.2).
            guard let colon = line.firstIndex(of: ":"), colon > line.startIndex,
                  line[..<colon].unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return false }
            fields.insert(String(line[..<colon]))
        }
        let mail: Set<String> = ["from", "received", "return-path", "message-id", "mime-version", "delivered-to", "dkim-signature",
                                 "arc-seal", "authentication-results", "in-reply-to", "references"]
        return fields.count >= 2 && !fields.isDisjoint(with: mail)
    }

    /// Text that carries MIME parts (a multipart type or a named part) at the start of a line. It did not read as a
    /// message, so it is held: its parts, a key file among them, are never passed on as plain text.
    static func carriesMIMEParts(_ text: String) -> Bool {
        // Folded header lines are unfolded first (RFC 5322 section 2.2.3), so a type or a name on a continuation
        // line is found as well.
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: #"\n[ \t]+"#, with: " ", options: .regularExpression)
        return unfolded.range(of: #"(?im)^content-(type|disposition)[ \t]*:[^\n]*(multipart/|name\*?[0-9]*\*?[ \t]*=)"#, options: .regularExpression) != nil
    }

    // MARK: - The entry point

    public static func extract(_ data: Data, name: String, limits: Limits = Limits()) -> Result {
        guard data.count <= limits.bytes else {
            return Result(kind: "unknown", text: "", textFrom: "parsed", problem: "larger than the size limit (\(data.count / 1_048_576) MB)")
        }
        let sniffed = sniff(data, name: name)
        var result: Result
        switch sniffed {
        case .pdf: result = pdf(data, limits: limits)
        case .png, .jpeg, .heic, .tiff: result = image(data, limits: limits)
        case .zip: result = office(data, name: name)
        case .rtf: result = rtf(data)
        case .markdownEmail: result = markdownEmail(decodedText(data))
        case .eml: result = eml(data)
        case .html, .text:
            // A message that did not read as one may carry an HTML part: it is held before either reading.
            let text = decodedText(data)
            result = carriesMIMEParts(text)
                ? Result(kind: "text", text: "", textFrom: "parsed", problem: "it looks like a mail message, but its headers do not read as one")
                // A script is held, never read as a note (adaptation-layer §4.5).
                : text.hasPrefix("#!") ? Result(kind: "text", text: "", textFrom: "parsed", problem: "a script, which Sprava does not read")
                : Result(kind: "text", text: sniffed == .html ? htmlText(text) : text, textFrom: "parsed")
        case .ole: result = Result(kind: "document", text: "", textFrom: "parsed", problem: "an old Office or Outlook format that is not read yet")
        case .unknown: result = Result(kind: "unknown", text: "", textFrom: "parsed", problem: "not a kind of file Sprava reads")
        }
        let (text, cut) = normalized(result.text, limit: limits.textChars)
        result.text = text
        // A reading stopped by the text limit is held, never passed on as if it were whole (adaptation-layer §2).
        if cut, result.problem == nil { result.problem = "longer than the text limit (\(limits.textChars) characters); only the start was read" }
        result.mismatch = nameMismatch(name, sniffed)
        return result
    }

    /// Text as `sniff` accepted it: UTF-8, else the Windows or Latin-1 single-byte text it fell back to, so an
    /// accented name is kept rather than turned into replacement characters.
    static func decodedText(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    static func nameMismatch(_ name: String, _ sniffed: Sniffed) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        let expected: [String: Set<Sniffed>] = [
            "pdf": [.pdf], "png": [.png], "jpg": [.jpeg], "jpeg": [.jpeg], "heic": [.heic], "tif": [.tiff], "tiff": [.tiff],
            "docx": [.zip], "xlsx": [.zip], "pptx": [.zip], "odt": [.zip], "rtf": [.rtf], "eml": [.eml], "html": [.html], "htm": [.html],
        ]
        guard let want = expected[ext] else { return false }
        return !want.contains(sniffed)
    }

    /// NFC, control and bidirectional characters removed, white space tidied, capped (adaptation-layer §3.1).
    public static func normalize(_ text: String, limit: Int) -> String { normalized(text, limit: limit).text }

    /// The same, and whether the cap cut the text.
    static func normalized(_ text: String, limit: Int) -> (text: String, cut: Bool) {
        var out = String.UnicodeScalarView()
        for s in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch s.value {
            case 0x0A, 0x09: out.append(s)
            case 0x0D: continue
            case 0x00...0x1F, 0x7F...0x9F, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: continue
            default: out.append(s)
            }
        }
        var s = String(out)
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Counted in Unicode scalars, not characters: one character can carry millions of combining marks, and the
        // cap is there to bound the size of what is passed on.
        return s.unicodeScalars.count > limit ? (String(String.UnicodeScalarView(s.unicodeScalars.prefix(limit))), true) : (s, false)
    }
}
