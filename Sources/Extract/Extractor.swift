import AppKit
import BinderFormat
import Compression
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

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
        if lower.range(of: #"^(received|return-path|from|message-id|mime-version|date|subject|to|delivered-to):"#, options: .regularExpression) != nil,
           lower.contains("\nsubject:") || lower.hasPrefix("subject:") { return .eml }
        if lower.contains("<html") || lower.contains("<!doctype html") { return .html }
        if data.prefix(4096).contains(0) { return .unknown }
        return .text
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
        case .png, .jpeg, .heic, .tiff: result = image(data)
        case .zip: result = office(data, name: name)
        case .rtf: result = rtf(data)
        case .html: result = Result(kind: "text", text: htmlText(String(decoding: data, as: UTF8.self)), textFrom: "parsed")
        case .markdownEmail: result = markdownEmail(String(decoding: data, as: UTF8.self))
        case .eml: result = eml(data)
        case .text: result = Result(kind: "text", text: String(decoding: data, as: UTF8.self), textFrom: "parsed")
        case .ole: result = Result(kind: "document", text: "", textFrom: "parsed", problem: "an old Office or Outlook format that is not read yet")
        case .unknown: result = Result(kind: "unknown", text: "", textFrom: "parsed", problem: "not a kind of file Sprava reads")
        }
        result.text = normalize(result.text, limit: limits.textChars)
        result.mismatch = nameMismatch(name, sniffed)
        return result
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
    public static func normalize(_ text: String, limit: Int) -> String {
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
        return s.count > limit ? String(s.prefix(limit)) : s
    }

    // MARK: - PDF: the text layer, OCR for pages without one, every page

    static func pdf(_ data: Data, limits: Limits) -> Result {
        guard let doc = PDFDocument(data: data) else { return Result(kind: "pdf", text: "", textFrom: "parsed", problem: "the PDF does not open") }
        if doc.isEncrypted && doc.isLocked { return Result(kind: "pdf", text: "", textFrom: "parsed", problem: "the PDF is protected by a password") }
        let count = doc.pageCount
        guard count <= limits.pages else { return Result(kind: "pdf", text: "", textFrom: "parsed", pages: count, problem: "more pages than the limit (\(count))") }
        var parts: [String] = []
        var ocrPages = 0
        for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if layer.count >= 20 {
                parts.append(layer)
            } else if let image = render(page) {
                ocrPages += 1
                parts.append(ocr(image))
            }
        }
        let from = ocrPages == 0 ? "text-layer" : (ocrPages == count ? "ocr" : "text-layer+ocr")
        return Result(kind: "pdf", text: parts.joined(separator: "\n\n"), textFrom: from, pages: count)
    }

    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5   // about 180 dpi, enough for OCR
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, w * h < 60_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    // MARK: - Images: OCR on the device

    static func image(_ data: Data) -> Result {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return Result(kind: "image", text: "", textFrom: "ocr", problem: "the image does not open")
        }
        return Result(kind: "image", text: ocr(img), textFrom: "ocr", pages: 1)
    }

    public static func ocr(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        let observations = request.results ?? []
        // Reading order: top to bottom, then left to right.
        let lines = observations.sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
        }.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: - RTF and HTML

    static func rtf(_ data: Data) -> Result {
        let text = (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string ?? ""
        return Result(kind: "document", text: text, textFrom: "parsed")
    }

    /// Text of an HTML page with no network: tags dropped, scripts and styles removed, entities decoded.
    public static func htmlText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"(?is)<(script|style|head)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<(br|/p|/div|/li|/tr|/h[1-6])[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (e, c) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Office formats (zip of XML): docx, xlsx, pptx, odt, ods, odp

    static func office(_ data: Data, name: String) -> Result {
        guard let entries = Zip.entries(data) else { return Result(kind: "document", text: "", textFrom: "parsed", problem: "the archive does not open") }
        let names = Set(entries.map(\.name))
        func xml(_ n: String) -> String? { entries.first { $0.name == n }.flatMap { Zip.read($0, in: data) }.map { String(decoding: $0, as: UTF8.self) } }
        var text = ""
        if let doc = xml("word/document.xml") {
            text = xmlText(doc, paragraph: "w:p", run: "w:t")
        } else if names.contains("xl/workbook.xml") {
            let shared = xml("xl/sharedStrings.xml").map { xmlStrings($0, tag: "t") } ?? []
            var rows: [String] = []
            for e in entries.filter({ $0.name.hasPrefix("xl/worksheets/sheet") }).sorted(by: { $0.name < $1.name }) {
                guard let sheet = Zip.read(e, in: data).map({ String(decoding: $0, as: UTF8.self) }) else { continue }
                rows += sheetRows(sheet, shared: shared)
            }
            text = rows.joined(separator: "\n")
        } else if names.contains(where: { $0.hasPrefix("ppt/slides/slide") }) {
            let slides = entries.filter { $0.name.hasPrefix("ppt/slides/slide") && $0.name.hasSuffix(".xml") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            text = slides.compactMap { Zip.read($0, in: data) }.map { xmlText(String(decoding: $0, as: UTF8.self), paragraph: "a:p", run: "a:t") }
                .joined(separator: "\n\n")
        } else if let content = xml("content.xml") {
            text = xmlText(content, paragraph: "text:p", run: nil)
        } else if names.contains(where: { $0.hasSuffix(".iwa") }) {
            return Result(kind: "document", text: "", textFrom: "parsed", problem: "an Apple iWork file; export it as PDF to have it read")
        } else {
            return Result(kind: "document", text: "", textFrom: "parsed", problem: "an archive, not a document Sprava reads")
        }
        return Result(kind: "document", text: text, textFrom: "parsed")
    }

    /// Text of XML paragraphs; `run` limits text to those elements (Word, PowerPoint), else all text nodes.
    static func xmlText(_ xml: String, paragraph: String, run: String?) -> String {
        var paragraphs: [String] = []
        for p in xml.components(separatedBy: "</\(paragraph)>") {
            var pieces: [String] = []
            if let run {
                var rest = Substring(p)
                while let open = rest.range(of: "<\(run)") {
                    guard let gt = rest[open.upperBound...].firstIndex(of: ">") else { break }
                    if rest[rest.index(before: gt)] == "/" { rest = rest[rest.index(after: gt)...]; continue }
                    guard let close = rest[gt...].range(of: "</\(run)>") else { break }
                    pieces.append(String(rest[rest.index(after: gt)..<close.lowerBound]))
                    rest = rest[close.upperBound...]
                }
            } else {
                pieces = [p.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)]
            }
            let line = decode(pieces.joined()).trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { paragraphs.append(line) }
        }
        return paragraphs.joined(separator: "\n")
    }

    static func xmlStrings(_ xml: String, tag: String) -> [String] {
        xml.components(separatedBy: "<si>").dropFirst().map { si in
            decode(si.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
        }
    }

    static func sheetRows(_ sheet: String, shared: [String]) -> [String] {
        sheet.components(separatedBy: "</row>").compactMap { row in
            var cells: [String] = []
            // A cell opens as `<c ...>` or plain `<c>`.
            let normalized = row.replacingOccurrences(of: "<c>", with: "<c >")
            for c in normalized.components(separatedBy: "<c ").dropFirst() {
                let isShared = c.contains("t=\"s\"")
                guard let v = c.range(of: "<v>"), let e = c.range(of: "</v>") else {
                    if let t = c.range(of: "<t>"), let te = c.range(of: "</t>") { cells.append(decode(String(c[t.upperBound..<te.lowerBound]))) }
                    continue
                }
                let raw = String(c[v.upperBound..<e.lowerBound])
                cells.append(isShared ? (Int(raw).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? raw) : raw)
            }
            return cells.isEmpty ? nil : cells.joined(separator: "\t")
        }
    }

    static func decode(_ s: String) -> String {
        var out = s
        for (e, c) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: e, with: c)
        }
        return out
    }

    // MARK: - Email: imap-extract's Markdown, and .eml

    /// imap-extract's export: front matter (subject, from, date, to), then the body as Markdown.
    static func markdownEmail(_ text: String) -> Result {
        let parts = text.components(separatedBy: "\n---\n")
        let front = parts.first ?? ""
        func field(_ key: String) -> String? {
            for line in front.split(separator: "\n") where line.lowercased().hasPrefix(key + ":") {
                var v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
                return v.replacingOccurrences(of: "\\\"", with: "\"")
            }
            return nil
        }
        let body = parts.dropFirst().joined(separator: "\n---\n")
        let email = Email(subject: field("subject"), from: field("from"), to: field("to"), date: field("date"), messageID: nil, attachments: [])
        return Result(kind: "email", text: body, textFrom: "parsed", email: email)
    }

    /// A MIME message: headers, the text body (plain preferred, else HTML as text), and attachments.
    static func eml(_ data: Data) -> Result {
        let raw = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        let (headers, body) = splitHeaders(raw)
        var plain: String?, html: String?
        var attachments: [Email.Attachment] = []
        walk(headers: headers, body: body, plain: &plain, html: &html, attachments: &attachments, depth: 0)
        let email = Email(subject: headers["subject"].map(decodeWords), from: headers["from"].map(decodeWords), to: headers["to"].map(decodeWords),
                          date: headers["date"], messageID: headers["message-id"], attachments: attachments)
        return Result(kind: "email", text: plain ?? html.map(htmlText) ?? "", textFrom: "parsed", email: email)
    }

    static func splitHeaders(_ s: String) -> ([String: String], String) {
        let parts = s.components(separatedBy: "\n\n")
        var headers: [String: String] = [:]
        var last: String?
        for line in (parts.first ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t", let k = last { headers[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces); continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].lowercased()
            headers[k] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            last = k
        }
        return (headers, parts.dropFirst().joined(separator: "\n\n"))
    }

    static func param(_ header: String?, _ name: String) -> String? {
        guard let header, let r = header.range(of: name + "=", options: .caseInsensitive) else { return nil }
        var v = header[r.upperBound...].prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") { v = String(v.dropFirst().prefix { $0 != "\"" }) }
        return v
    }

    /// A file name parameter in any form a mail program writes: plain (`name="a.txt"`), RFC 2231 extended
    /// (`name*=utf-8''a.txt`) or continued (`name*0=`, `name*1*=`). Every form names the part.
    static func fileParam(_ header: String?, _ name: String) -> String? {
        guard let header else { return nil }
        var plain: String?
        var pieces: [(Int, String)] = []
        for field in header.split(separator: ";").dropFirst() {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let key = field[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = field[field.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") { value = String(value.dropFirst().prefix { $0 != "\"" }) }
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

    static func walk(headers: [String: String], body: String, plain: inout String?, html: inout String?,
                     attachments: inout [Email.Attachment], depth: Int) {
        guard depth < 6 else { return }
        let type = (headers["content-type"] ?? "text/plain").lowercased()
        if type.hasPrefix("multipart/"), let boundary = param(headers["content-type"], "boundary") {
            for part in body.components(separatedBy: "--" + boundary).dropFirst() {
                if part.hasPrefix("--") { break }
                let (h, b) = splitHeaders(String(part.drop { $0 == "\n" }))
                walk(headers: h, body: b, plain: &plain, html: &html, attachments: &attachments, depth: depth + 1)
            }
            return
        }
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        let bytes: Data
        switch encoding {
        case "base64": bytes = Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data()
        case "quoted-printable": bytes = Data(quotedPrintable(body).utf8)
        default: bytes = Data(body.utf8)
        }
        let disposition = headers["content-disposition"]?.lowercased() ?? ""
        let filename = (fileParam(headers["content-disposition"], "filename") ?? fileParam(headers["content-type"], "name")).map(decodeWords)
        // A part named like a key or credential file (binder-v0 §3.3) is an attachment whatever its type or
        // disposition, inline included: it never becomes the body. Its bytes stay here, and its name is reduced to
        // the last path component, so the intake reading still knows it and skips it with a note.
        if let filename, DocumentPaths.isKeyFile(filename) {
            attachments.append(Email.Attachment(name: DocumentPaths.safeName((filename as NSString).lastPathComponent), data: Data()))
        } else if disposition.hasPrefix("attachment") || (filename != nil && !type.hasPrefix("text/")) {
            attachments.append(Email.Attachment(name: DocumentPaths.safeName(filename ?? "attachment"), data: bytes))
        } else if type.hasPrefix("text/plain"), plain == nil {
            plain = String(decoding: bytes, as: UTF8.self)
        } else if type.hasPrefix("text/html"), html == nil {
            html = String(decoding: bytes, as: UTF8.self)
        }
    }

    static func quotedPrintable(_ s: String) -> String {
        var bytes: [UInt8] = []
        let chars = Array(s.replacingOccurrences(of: "=\n", with: "").utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == UInt8(ascii: "="), i + 2 < chars.count, let v = UInt8(String(decoding: chars[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(v); i += 3
            } else { bytes.append(chars[i]); i += 1 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

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

/// A minimal reader for zip archives (stored and deflated entries), enough for office documents.
public enum Zip {
    public struct Entry: Sendable { public let name: String; let method: UInt16; let compressed: Int; let size: Int; let offset: Int }

    static func u16(_ d: Data, _ o: Int) -> UInt16 { o + 2 <= d.count ? UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 : 0 }
    static func u32(_ d: Data, _ o: Int) -> UInt32 { o + 4 <= d.count ? UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16 : 0 }

    public static func entries(_ d: Data) -> [Entry]? {
        // The end of central directory record, searched from the end.
        var eocd = -1
        var i = d.count - 22
        while i >= max(0, d.count - 65_557) {
            if u32(d, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = Int(u16(d, eocd + 10))
        var p = Int(u32(d, eocd + 16))
        var out: [Entry] = []
        for _ in 0..<min(count, 10_000) {
            guard u32(d, p) == 0x02014b50 else { return nil }
            let method = u16(d, p + 10)
            let comp = Int(u32(d, p + 20)), size = Int(u32(d, p + 24))
            let nameLen = Int(u16(d, p + 28)), extra = Int(u16(d, p + 30)), comment = Int(u16(d, p + 32))
            let local = Int(u32(d, p + 42))
            guard p + 46 + nameLen <= d.count else { return nil }
            let name = String(decoding: d[(d.startIndex + p + 46)..<(d.startIndex + p + 46 + nameLen)], as: UTF8.self)
            out.append(Entry(name: name, method: method, compressed: comp, size: size, offset: local))
            p += 46 + nameLen + extra + comment
        }
        return out
    }

    public static func read(_ e: Entry, in d: Data) -> Data? {
        guard u32(d, e.offset) == 0x04034b50, e.size <= 100 * 1024 * 1024 else { return nil }
        let start = e.offset + 30 + Int(u16(d, e.offset + 26)) + Int(u16(d, e.offset + 28))
        guard start + e.compressed <= d.count else { return nil }
        let payload = d[(d.startIndex + start)..<(d.startIndex + start + e.compressed)]
        switch e.method {
        case 0: return Data(payload)
        case 8:
            guard e.size > 0, e.compressed > 0 else { return Data() }
            var out = Data(count: e.size)
            let n = out.withUnsafeMutableBytes { dst in
                payload.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, e.compressed, nil, COMPRESSION_ZLIB)
                }
            }
            return n == e.size ? out : nil
        default: return nil
        }
    }
}
