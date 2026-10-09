import BinderFormat
import Foundation

extension Extractor {
    // MARK: - Email: imap-extract's Markdown, and .eml

    /// imap-extract's export: front matter (subject, from, date, to), then the body as Markdown.
    static func markdownEmail(_ text: String) -> Result {
        // Split once, at the first separator: the body is everything after it, however many it holds.
        let cut = text.range(of: "\n---\n")
        let front = cut.map { text[..<$0.lowerBound] } ?? text[...]
        func field(_ key: String) -> String? {
            for line in front.split(separator: "\n") where line.lowercased().hasPrefix(key + ":") {
                var v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
                return v.replacingOccurrences(of: "\\\"", with: "\"")
            }
            return nil
        }
        let body = cut.map { String(text[$0.upperBound...]) } ?? ""
        let email = Email(subject: field("subject"), from: field("from"), to: field("to"), date: field("date"), messageID: nil, attachments: [])
        return Result(kind: "email", text: body, textFrom: "parsed", email: email)
    }

    /// A MIME message: headers, the text body (plain preferred, else HTML as text), and attachments.
    static func eml(_ data: Data, limits: Limits = Limits()) -> Result {
        let raw = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        let (headers, body) = splitHeaders(raw)
        var attachments: [Email.Attachment] = []
        var state = Walk(maxParts: limits.parts)
        let text = walk(headers: headers, body: body, attachments: &attachments, state: &state, depth: 0)?.text ?? ""
        let email = Email(subject: headers["subject"].map(decodeWords), from: headers["from"].map(decodeWords), to: headers["to"].map(decodeWords),
                          date: headers["date"], messageID: headers["message-id"], attachments: attachments)
        // Parts past the nesting or part limits were not read, so the message is held rather than passed on as whole.
        let problem = state.tooDeep ? "its parts nest deeper than \(maxDepth) levels; the deeper ones were not read"
            : state.tooMany ? "it has more than \(limits.parts) parts; the later ones were not read" : nil
        return Result(kind: "email", text: text, textFrom: "parsed", email: email, problem: problem)
    }

    /// What a walk through one message found past its limits, and how many parts it has met so far.
    struct Walk { let maxParts: Int; var parts = 0; var tooDeep = false; var tooMany = false }

    /// The header fields of an entity and its body, split at the first empty line.
    static func splitHeaders(_ s: String) -> ([String: String], String) {
        let blank = s.range(of: "\n\n")
        let block = blank.map { s[..<$0.lowerBound] } ?? s[...]
        var headers: [String: String] = [:]
        var last: String?
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t", let k = last { headers[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces); continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].lowercased()
            headers[k] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            last = k
        }
        return (headers, blank.map { String(s[$0.upperBound...]) } ?? "")
    }

    /// The parameters after a header's value, as (lowercased key, value) pairs. A quoted value is one value whatever
    /// it holds, a semicolon included, and a backslash in it escapes the next character (RFC 2045 section 5.1).
    static func parameters(_ header: String) -> [(key: String, value: String)] {
        var fields: [String] = [], field = "", quoted = false, escaped = false
        for c in header {
            if escaped { field.append(c); escaped = false; continue }
            if quoted, c == "\\" { field.append(c); escaped = true; continue }
            if c == "\"" { quoted.toggle() }
            if c == ";", !quoted { fields.append(field); field = ""; continue }
            field.append(c)
        }
        fields.append(field)
        return fields.dropFirst().compactMap { field in
            guard let eq = field.firstIndex(of: "=") else { return nil }
            let key = field[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = field[field.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard raw.hasPrefix("\"") else { return (key, raw) }
            var value = "", escaped = false
            for c in raw.dropFirst() {
                if escaped { value.append(c); escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { break } else { value.append(c) }
            }
            return (key, value)
        }
    }

    static func param(_ header: String?, _ name: String) -> String? {
        guard let header else { return nil }
        return parameters(header).first { $0.key == name.lowercased() }?.value
    }

    /// A file name parameter in any form a mail program writes: plain (`name="a.txt"`), RFC 2231 extended
    /// (`name*=utf-8''a.txt`) or continued (`name*0=`, `name*1*=`). Every form names the part.
    static func fileParam(_ header: String?, _ name: String) -> String? {
        guard let header else { return nil }
        var plain: String?
        var pieces: [(Int, String)] = []
        for (key, parameter) in parameters(header) {
            var value = parameter
            if key == name { plain = plain ?? value; continue }
            guard key.hasPrefix(name + "*") else { continue }
            var rest = key.dropFirst(name.count + 1)
            let extended = rest.hasSuffix("*") || rest.isEmpty
            if rest.hasSuffix("*") { rest = rest.dropLast() }
            guard let index = rest.isEmpty ? 0 : Int(rest), (0..<100).contains(index) else { continue }
            if extended, index == 0, let quote = value.firstIndex(of: "'"),
               let second = value[value.index(after: quote)...].firstIndex(of: "'") {
                value = String(value[value.index(after: second)...])   // drop charset'language'
            }
            pieces.append((index, extended ? (value.removingPercentEncoding ?? value) : value))
        }
        if !pieces.isEmpty { return pieces.sorted { $0.0 < $1.0 }.map(\.1).joined() }
        return plain
    }

    static let maxDepth = 6

    /// The text of one MIME entity, and whether it came from plain text alone (the representation preferred).
    struct Body { var text: String; var plain: Bool }

    /// The body of an entity, collecting its attachments. Of a `multipart/alternative`, one representation is the
    /// body (plain text first); the parts of any other multipart are independent content, so every body part is
    /// kept, in order. A text part with a file name inside a multipart is an attachment, never a dropped part.
    static func walk(headers: [String: String], body: String, attachments: inout [Email.Attachment], state: inout Walk, depth: Int) -> Body? {
        guard depth < maxDepth else { state.tooDeep = true; return nil }
        let type = (headers["content-type"] ?? "text/plain").lowercased()
        let disposition = headers["content-disposition"]?.lowercased() ?? ""
        let filename = (fileParam(headers["content-disposition"], "filename") ?? fileParam(headers["content-type"], "name")).map(decodeWords)
        // A part named like a key or credential file (binder-v0 §3.3) is an attachment whatever its type or
        // disposition, inline or multipart included: neither it nor any part inside it becomes the body. Its bytes
        // stay here, and its name is reduced to the last path component, so the intake reading still knows it and
        // skips it with a note.
        if let filename, DocumentPaths.isKeyFile(filename) {
            attachments.append(Email.Attachment(name: DocumentPaths.safeName((filename as NSString).lastPathComponent), data: Data()))
            return nil
        }
        if type.hasPrefix("multipart/"), let boundary = param(headers["content-type"], "boundary") {
            var bodies: [Body] = []
            // Parts are taken one at a time, never split all at once, and stop at the message's part limit: a body
            // of a million delimiters is neither a million strings nor a million attachments to read.
            let delimiter = "--" + boundary
            var rest = body.range(of: delimiter).map { body[$0.upperBound...] }
            while let current = rest, !current.hasPrefix("--") {
                state.parts += 1
                guard state.parts <= state.maxParts else { state.tooMany = true; break }
                let end = current.range(of: delimiter)
                let part = end.map { current[..<$0.lowerBound] } ?? current
                let (h, b) = splitHeaders(String(part.drop { $0 == "\n" }))
                if let found = walk(headers: h, body: b, attachments: &attachments, state: &state, depth: depth + 1) { bodies.append(found) }
                rest = end.map { current[$0.upperBound...] }
            }
            // An empty representation is no body when another one holds the text.
            let filled = bodies.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if type.hasPrefix("multipart/alternative") { return filled.first(where: \.plain) ?? filled.first ?? bodies.first }
            return bodies.isEmpty ? nil : Body(text: bodies.map(\.text).joined(separator: "\n\n"), plain: bodies.allSatisfy(\.plain))
        }
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        let bytes: Data
        switch encoding {
        case "base64": bytes = Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data()
        case "quoted-printable": bytes = quotedPrintableData(body)
        default: bytes = Data(body.utf8)
        }
        if disposition.hasPrefix("attachment") || (filename != nil && (depth > 0 || !type.hasPrefix("text/"))) {
            attachments.append(Email.Attachment(name: DocumentPaths.safeName(filename ?? "attachment"), data: bytes))
        } else if type.hasPrefix("text/plain") {
            return Body(text: String(decoding: bytes, as: UTF8.self), plain: true)
        } else if type.hasPrefix("text/html") {
            return Body(text: htmlText(String(decoding: bytes, as: UTF8.self)), plain: false)
        }
        return nil
    }

    /// Quoted-printable bytes as they were: a binary part keeps every byte, text is decoded by its reader.
    static func quotedPrintableData(_ s: String) -> Data {
        var bytes: [UInt8] = []
        let chars = Array(s.replacingOccurrences(of: "=\n", with: "").utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == UInt8(ascii: "="), i + 2 < chars.count, let v = UInt8(String(decoding: chars[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(v); i += 3
            } else { bytes.append(chars[i]); i += 1 }
        }
        return Data(bytes)
    }

    static func quotedPrintable(_ s: String) -> String { String(decoding: quotedPrintableData(s), as: UTF8.self) }

    /// RFC 2047 encoded words (=?utf-8?B?...?= and =?utf-8?Q?...?=).
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var out = s
        while let r = out.range(of: #"=\?[^?]+\?[BbQq]\?[^?]*\?="#, options: .regularExpression) {
            let word = String(out[r])
            let parts = word.dropFirst(2).dropLast(2).split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
            var decoded = ""
            if parts.count == 3 {
                if parts[1].uppercased() == "B" { decoded = Data(base64Encoded: String(parts[2])).map { String(decoding: $0, as: UTF8.self) } ?? "" }
                else { decoded = quotedPrintable(parts[2].replacingOccurrences(of: "_", with: " ")) }
            }
            out.replaceSubrange(r, with: decoded)
        }
        return out
    }
}
