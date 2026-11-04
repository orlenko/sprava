import Clerk
import Foundation

/// An email draft as RFC 5322 / MIME bytes, for the person to send from their own mail program (issue #592,
/// integrations.md §5.2). Pure: it reads no file and writes none, and nothing here sends.
///
/// Every string may come from a model or a document, so each is checked before it reaches a header: an address must
/// be exactly one well-formed ASCII address, a message id `<left@right>`, and no header text may hold a control or
/// line-breaking character. Every header line is ASCII and folded at 78 columns where it has a place to fold.
/// A failure names the field or limit, never the value, so it can be logged without the draft's content.
public struct MailDraft: Sendable {
    public struct Mailbox: Sendable, Equatable {
        public var name: String
        public var address: String
        public init(name: String = "", address: String) { self.name = name; self.address = address }
    }

    public struct Attachment: Sendable, Equatable {
        public var filename: String
        public var data: Data
        public init(filename: String, data: Data) { self.filename = filename; self.data = data }
    }

    public enum Limit: String, Sendable { case attachmentBytes, attachments }

    public struct Limits: Sendable {
        /// Raw attachment bytes together, before base64 (about 24 MiB on the wire, under common 25 MB caps).
        public var attachmentBytes = 18 * 1024 * 1024
        public var attachments = 100
        public init() {}
    }

    public enum Failure: Error, Equatable {
        case address(field: String)
        case headerText(field: String)
        case messageID(field: String)
        /// The attachment at this index has no usable file name.
        case filename(index: Int)
        case overLimit(Limit)
        /// The boundary generator gave an unusable token, or only tokens found inside the content.
        case boundary
    }

    /// The whole message, CRLF line endings, ready for an IMAP APPEND or an `.eml` file.
    public let rfc822: Data
    /// The multipart boundary used, when there are attachments.
    public let boundary: String?

    /// `unsent` adds `X-Unsent: 1`, which makes Mail and Outlook open an `.eml` file as a message to edit and send.
    /// `boundary` gives the random part of the multipart boundary (letters and digits); tests pass a fixed one.
    public init(from: Mailbox, to: [Mailbox], cc: [Mailbox] = [], subject: String, body: String,
                attachments: [Attachment] = [], inReplyTo: String? = nil, references: [String] = [],
                messageID: String, date: Date, timeZone: TimeZone = .current, unsent: Bool = false,
                limits: Limits = Limits(), boundary: () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "") }) throws {
        guard attachments.count <= limits.attachments else { throw Failure.overLimit(.attachments) }
        guard attachments.reduce(0, { $0 + $1.data.count }) <= limits.attachmentBytes else { throw Failure.overLimit(.attachmentBytes) }
        guard Self.plain(subject) else { throw Failure.headerText(field: "Subject") }

        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.timeZone = timeZone
        dateFormat.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var head = Self.header("Date", [dateFormat.string(from: date)])
        head += Self.header("From", try Self.mailboxes([from], field: "From"))
        if !to.isEmpty { head += Self.header("To", try Self.mailboxes(to, field: "To")) }
        if !cc.isEmpty { head += Self.header("Cc", try Self.mailboxes(cc, field: "Cc")) }
        head += Self.header("Subject", Self.unstructured(subject))
        head += Self.header("Message-ID", [try Self.messageID(messageID, field: "Message-ID")])
        if let inReplyTo { head += Self.header("In-Reply-To", [try Self.messageID(inReplyTo, field: "In-Reply-To")]) }
        if !references.isEmpty { head += Self.header("References", try references.map { try Self.messageID($0, field: "References") }) }
        head += "MIME-Version: 1.0\r\n"
        if unsent { head += "X-Unsent: 1\r\n" }

        let text = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            + Self.quotedPrintable(body)
        guard !attachments.isEmpty else {
            rfc822 = Data((head + text + "\r\n").utf8)
            self.boundary = nil
            return
        }
        var parts = [text]
        for (index, attachment) in attachments.enumerated() {
            parts.append(try Self.part(attachment, index: index))
        }
        // "=_" never occurs in quoted-printable or base64 output, so only a part's headers could hold the boundary;
        // each candidate is still checked against every part.
        var chosen: String?
        for _ in 0..<8 {
            let token = boundary()
            guard (1...60).contains(token.count), token.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else { break }
            let candidate = "=_" + token
            if !parts.contains(where: { $0.contains(candidate) }) { chosen = candidate; break }
        }
        guard let chosen else { throw Failure.boundary }
        head += "Content-Type: multipart/mixed; boundary=\"\(chosen)\"\r\n\r\nThis is a message in MIME format.\r\n"
        rfc822 = Data((head + parts.map { "--\(chosen)\r\n\($0)\r\n" }.joined() + "--\(chosen)--\r\n").utf8)
        self.boundary = chosen
    }

    // MARK: - Checks

    /// Text with no control, line or paragraph separator character: nothing that can end a header line.
    static func plain(_ s: String, bidi: Bool = false) -> Bool {
        s.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return false
            default: return !(bidi && directional.contains(scalar.value))
            }
        }
    }

    /// Characters that reorder text on screen, so a name could show something other than what it holds.
    static let directional: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

    static let atext = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/=?^_`{|}~")

    static func messageID(_ s: String, field: String) throws -> String {
        let halves = s.dropFirst().dropLast().split(separator: "@", omittingEmptySubsequences: false)
        guard s.hasPrefix("<"), s.hasSuffix(">"), s.utf8.count <= 250, halves.count == 2, halves.allSatisfy({ half in
            !half.isEmpty && !half.hasPrefix(".") && !half.hasSuffix(".") && !half.contains("..")
                && half.unicodeScalars.allSatisfy { $0 == "." || ($0.isASCII && atext.contains($0)) }
        }) else { throw Failure.messageID(field: field) }
        return s
    }

    // MARK: - Headers

    /// `Name: words`, the words joined by spaces and folded before any word that would pass column 78.
    static func header(_ name: String, _ words: [String]) -> String {
        var lines: [String] = [], line = name + ":", empty = true
        for word in words {
            if !empty, line.count + 1 + word.count > 78 { lines.append(line); line = "" }
            line += " " + word
            empty = false
        }
        lines.append(line)
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Plain ASCII words as they are; anything else as RFC 2047 encoded words of whole characters.
    static func unstructured(_ s: String) -> [String] {
        let ascii = s.unicodeScalars.allSatisfy { (0x20..<0x7F).contains($0.value) }
        let words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if ascii, !s.contains("=?"), words.allSatisfy({ !$0.isEmpty && $0.count <= 70 }) { return words }
        return encodedWords(s)
    }

    /// UTF-8 base64 encoded words of at most 45 bytes each (72 columns), split only between characters.
    static func encodedWords(_ s: String) -> [String] {
        var words: [String] = [], chunk = Data()
        for scalar in s.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if chunk.count + bytes.count > 45 { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?="); chunk = Data() }
            chunk += bytes
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
        return words
    }

    /// `name <address>, …` as words to fold. A short plain-ASCII name is a quoted string; any other, encoded words.
    static func mailboxes(_ list: [Mailbox], field: String) throws -> [String] {
        var words: [String] = []
        for (i, mailbox) in list.enumerated() {
            let address = mailbox.address.trimmingCharacters(in: .whitespaces)
            // No "=?" (an encoded word a decoding parser could turn into another address), "%" or "!" (old
            // source-routing forms a relay could deliver elsewhere).
            guard plain(mailbox.address), address.unicodeScalars.allSatisfy(\.isASCII), !address.contains("=?"),
                  !address.contains("%"), !address.contains("!"), MailAddress.single(address) != nil else { throw Failure.address(field: field) }
            // No "@" in a name: "x@real.example" <other@example.com> would show as an address it is not.
            guard plain(mailbox.name, bidi: true), !mailbox.name.contains("@"), !mailbox.name.contains("\u{FF20}") else {
                throw Failure.headerText(field: field)
            }
            let name = mailbox.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                words.append(address)
            } else {
                if name.count <= 60, !name.contains("=?"), name.unicodeScalars.allSatisfy({ (0x20..<0x7F).contains($0.value) }) {
                    words.append("\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"")
                } else {
                    words += encodedWords(name)
                }
                words.append("<\(address)>")
            }
            if i < list.count - 1 { words[words.count - 1] += "," }
        }
        return words
    }

    // MARK: - Parts

    /// Text as quoted-printable, CRLF line endings, no encoded line past 76 columns.
    static func quotedPrintable(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        for line in lines {
            let bytes = Array(line.utf8)
            var current = ""
            for (i, byte) in bytes.enumerated() {
                let literal = ((33...126).contains(byte) && byte != UInt8(ascii: "=")) || ((byte == 32 || byte == 9) && i < bytes.count - 1)
                let token = literal ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
                if current.count + token.count > 75 { out.append(current + "="); current = "" }
                current += token
            }
            out.append(current)
        }
        return out.joined(separator: "\r\n")
    }

    static let types = [
        "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "heic": "image/heic", "tif": "image/tiff", "tiff": "image/tiff", "txt": "text/plain", "md": "text/markdown",
        "csv": "text/csv", "ics": "text/calendar", "json": "application/json", "zip": "application/zip", "rtf": "application/rtf",
        "doc": "application/msword", "xls": "application/vnd.ms-excel",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ]

    /// The last path component of `raw`, refused when it is empty, a dot name, too long, or holds a control or
    /// direction character.
    static func filename(_ raw: String, index: Int) throws -> String {
        let name = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255, plain(name, bidi: true) else { throw Failure.filename(index: index) }
        return name.precomposedStringWithCanonicalMapping
    }

    /// RFC 2231 attr-chars, kept as they are in an encoded parameter; every other byte is %XX.
    static let attrChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~")

    static func part(_ attachment: Attachment, index: Int) throws -> String {
        let name = try filename(attachment.filename, index: index)
        let ext = (name as NSString).pathExtension.lowercased()
        // An ASCII stand-in for readers without RFC 2231, at most 60 characters, keeping the extension.
        var fallback = String(String.UnicodeScalarView(name.unicodeScalars.map { (0x20..<0x7F).contains($0.value) && $0 != "\"" && $0 != "\\" ? $0 : "_" }))
        if fallback.count > 60 {
            let suffix = ext.isEmpty || ext.count > 10 ? "" : "." + ext
            fallback = String(fallback.prefix(60 - suffix.count)) + suffix
        }
        // The encoded name in pieces of at most 48 columns (RFC 2231 continuations), split only between characters
        // so each piece decodes on its own.
        var pieces: [String] = [], piece = ""
        for scalar in name.unicodeScalars {
            let token = attrChars.contains(scalar) ? String(scalar) : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
            if !piece.isEmpty, piece.count + token.count > 48 { pieces.append(piece); piece = "" }
            piece += token
        }
        pieces.append(piece)
        var disposition = ["attachment;", "filename=\"\(fallback)\";"]
        disposition += pieces.count == 1 ? ["filename*=UTF-8''\(pieces[0])"]
            : pieces.enumerated().map { i, p in "filename*\(i)*=\(i == 0 ? "UTF-8''" : "")\(p)\(i < pieces.count - 1 ? ";" : "")" }
        return header("Content-Type", ["\(types[ext] ?? "application/octet-stream");", "name=\"\(fallback)\""])
            + header("Content-Disposition", disposition)
            + "Content-Transfer-Encoding: base64\r\n\r\n"
            + attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }
}
