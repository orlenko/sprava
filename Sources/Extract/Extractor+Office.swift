import AppKit
import Compression
import Foundation

extension Extractor {
    // MARK: - RTF and HTML

    static func rtf(_ data: Data) -> Result {
        // A file that does not parse is held (adaptation-layer §4.5), never passed on as a document with no text.
        guard let text = (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string else {
            return Result(kind: "document", text: "", textFrom: "parsed", problem: "the RTF file does not parse")
        }
        return Result(kind: "document", text: text, textFrom: "parsed")
    }

    /// Text of an HTML page with no network: tags dropped, scripts and styles removed, entities decoded.
    public static func htmlText(_ html: String) -> String {
        // An element whose content is never page text goes whole: opened in any case, with or without attributes,
        // and closed by its end tag in any form the HTML tokenizer accepts (`</script >`, `</SCRIPT foo>`), or, when
        // it is never closed, by the end of the page.
        var s = html.replacingOccurrences(of: #"(?is)<(script|style|noscript|template)(?=[\s/>])[^>]*>.*?(?:</\1(?=[\s/>])[^>]*>|\z)"#,
                                          with: " ", options: .regularExpression)
        // The head's end tag may be left out: it ends at `</head>`, or where the HTML parser closes it, at the first
        // thing a head cannot hold (`<body>`, any other content tag, or text). So only what a head holds is taken:
        // white space, comments, a title with its text, and the empty head elements; never the body after it.
        s = s.replacingOccurrences(of: #"(?is)<head(?=[\s/>])[^>]*>(?:\s+|<!--.*?-->|<title(?=[\s/>])[^>]*>.*?(?:</title(?=[\s/>])[^>]*>|\z)|</?(?:base|basefont|bgsound|link|meta|noframes)(?=[\s/>])[^>]*>)*(?:</head(?=[\s/>])[^>]*>)?"#,
                                   with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<(br|/p|/div|/li|/tr|/h[1-6])[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (e, c) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Office formats (zip of XML): docx, xlsx, pptx, odt, ods, odp

    static func office(_ data: Data, name: String, limits: Limits = Limits()) -> Result {
        guard let entries = Zip.entries(data) else { return Result(kind: "document", text: "", textFrom: "parsed", problem: "the archive does not open") }
        let names = Set(entries.map(\.name))
        // A content part that is listed but does not read holds the whole document: the parts that did read are not
        // the document, and a reading never passes as whole when it is not.
        var unread: String?
        // Every part read counts against one budget, by the size it declares, before it is unpacked: many small
        // parts that each unpack to a lot, or many entries pointing at the same stored bytes, never add up past it
        // (adaptation-layer §2). A stored part is copied whole, so the larger of its two sizes counts.
        var budget = limits.unpacked, overBudget = false
        func read(_ e: Zip.Entry) -> String {
            let cost = max(e.size, e.compressed)
            guard !overBudget, cost <= budget else { overBudget = true; return "" }
            budget -= cost
            guard let bytes = Zip.read(e, in: data) else { unread = unread ?? e.name; return "" }
            return String(decoding: bytes, as: UTF8.self)
        }
        func tooLarge() -> Result {
            Result(kind: "document", text: "", textFrom: "parsed", problem: "it unpacks to more than the size limit (\(limits.unpacked / 1_048_576) MB)")
        }
        func xml(_ n: String) -> String? { entries.first { $0.name == n }.map(read) }
        // A password-protected OpenDocument lists its encrypted parts in its manifest: it is held, never read as if
        // its encrypted bytes were its text (adaptation-layer §4.5).
        if xml("META-INF/manifest.xml")?.contains("encryption-data") == true {
            return Result(kind: "document", text: "", textFrom: "parsed", problem: "the document is protected by a password")
        }
        if overBudget { return tooLarge() }
        var text = ""
        if let doc = xml("word/document.xml") {
            text = xmlText(doc, paragraph: "w:p", run: "w:t")
        } else if names.contains("xl/workbook.xml") {
            let shared = xml("xl/sharedStrings.xml").map { xmlStrings($0, tag: "t") } ?? []
            var rows: [String] = []
            for e in entries.filter({ $0.name.hasPrefix("xl/worksheets/sheet") }).sorted(by: { $0.name < $1.name }) {
                guard let sheet = sheetRows(read(e), shared: shared) else { unread = unread ?? e.name; continue }
                rows += sheet
            }
            text = rows.joined(separator: "\n")
        } else if names.contains(where: { $0.hasPrefix("ppt/slides/slide") }) {
            let slides = entries.filter { $0.name.hasPrefix("ppt/slides/slide") && $0.name.hasSuffix(".xml") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            text = slides.map { xmlText(read($0), paragraph: "a:p", run: "a:t") }.joined(separator: "\n\n")
        } else if let content = xml("content.xml") {
            text = xmlText(content, paragraph: "text:p", run: nil)
        } else if names.contains(where: { $0.hasSuffix(".iwa") }) {
            return Result(kind: "document", text: "", textFrom: "parsed", problem: "an Apple iWork file; export it as PDF to have it read")
        } else {
            return Result(kind: "document", text: "", textFrom: "parsed", problem: "an archive, not a document Sprava reads")
        }
        if overBudget { return tooLarge() }
        if let unread { return Result(kind: "document", text: "", textFrom: "parsed", problem: "a part of the document (\(unread)) does not read") }
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
                    // The whole element name: `<w:t>` or `<w:t xml:space=...>`, never `<w:tbl>` or `<w:tab/>`.
                    let next = rest[open.upperBound]
                    if rest[rest.index(before: gt)] == "/" || !(next == ">" || next == "/" || next.isWhitespace) {
                        rest = rest[rest.index(after: gt)...]; continue
                    }
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

    /// The rows of a worksheet, one tab-separated line each; nil when a cell's value is not closed after it opens,
    /// so a malformed sheet holds the document instead of passing as read.
    static func sheetRows(_ sheet: String, shared: [String]) -> [String]? {
        var rows: [String] = []
        for row in sheet.components(separatedBy: "</row>") {
            var cells: [String] = []
            // A cell opens as `<c ...>` or plain `<c>`.
            let normalized = row.replacingOccurrences(of: "<c>", with: "<c >")
            for c in normalized.components(separatedBy: "<c ").dropFirst() {
                let isShared = c.contains("t=\"s\"")
                // A closing tag is looked for only after its opening tag.
                if let v = c.range(of: "<v>") {
                    guard let e = c[v.upperBound...].range(of: "</v>") else { return nil }
                    let raw = String(c[v.upperBound..<e.lowerBound])
                    cells.append(isShared ? (Int(raw).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? raw) : raw)
                } else if let t = c.range(of: "<t>") {
                    guard let te = c[t.upperBound...].range(of: "</t>") else { return nil }
                    cells.append(decode(String(c[t.upperBound..<te.lowerBound])))
                }
            }
            if !cells.isEmpty { rows.append(cells.joined(separator: "\t")) }
        }
        return rows
    }

    static func decode(_ s: String) -> String {
        var out = s
        for (e, c) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: e, with: c)
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
        // More entries than the limit is no archive that opens: a partial listing would read as the whole document.
        let count = Int(u16(d, eocd + 10))
        guard count <= 10_000 else { return nil }
        var p = Int(u32(d, eocd + 16))
        var out: [Entry] = []
        for _ in 0..<count {
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
