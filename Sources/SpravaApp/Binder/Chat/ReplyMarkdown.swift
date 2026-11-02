import AppKit
import Foundation
import SwiftUI

/// The little Markdown a reply uses: headings, bullet and numbered lists, code, bold, italics and links. Nothing is ever
/// loaded: an image stays its alt text. A link runs only when the person clicks it, and only to the web, to mail, or to show
/// a file of this binder in Finder; a link that shows other words names its host beside them, since a reply can repeat
/// what a document told it to write (decisions.md D30).
enum ReplyMarkdown {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case item(marker: String, depth: Int, text: String)
        case paragraph(String)
        case code(String)
        case rule
    }

    /// Past this a reply is drawn as plain text: it is no answer to read, and a block per line would be slow.
    static let longestRendered = 256 * 1024
    static let fileScheme = "sprava-binder-file"

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = [], paragraph: [String] = [], fence: [String]?
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = fence { blocks.append(.code(lines.joined(separator: "\n"))); fence = nil } else { flush(); fence = [] }
                continue
            }
            if fence != nil { fence?.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            if let (level, heading) = heading(trimmed) { flush(); blocks.append(.heading(level: level, text: heading)); continue }
            if isRule(trimmed) { flush(); blocks.append(.rule); continue }
            if let (marker, rest) = marker(trimmed) {
                flush()
                let width = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                blocks.append(.item(marker: marker, depth: min(width / 2, 4), text: rest))
                continue
            }
            // An indented line under a list item goes on with that item.
            if paragraph.isEmpty, line.first == " " || line.first == "\t", case .item(let marker, let depth, let body)? = blocks.last {
                blocks[blocks.count - 1] = .item(marker: marker, depth: depth, text: body + "\n" + trimmed)
                continue
            }
            paragraph.append(line)
        }
        flush()
        if let fence { blocks.append(.code(fence.joined(separator: "\n"))) }
        return blocks
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        var text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, "-*_".contains(first) else { return false }
        return line.allSatisfy { $0 == first }
    }

    private static func marker(_ line: String) -> (String, String)? {
        if let first = line.first, "-*+\u{2022}".contains(first), line.dropFirst().first == " " {
            let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : ("\u{2022}", rest)
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        // Three digits at most, so a line that opens with a year stays a sentence.
        guard (1...3).contains(digits.count), let mark = line.dropFirst(digits.count).first, mark == "." || mark == ")",
              line.dropFirst(digits.count + 1).first == " " else { return nil }
        let rest = line.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : ("\(digits).", rest)
    }

    /// Bold, italics, code and links in a line. Every link is checked here; what passes is all that can be clicked.
    static func inline(_ text: String, folder: URL?) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var result = try? AttributedString(markdown: keepingAngleBrackets(text), options: options) else { return AttributedString(text) }
        for run in result.runs.reversed() {
            let words = String(result[run.range].characters)
            if let target = run.link {
                result[run.range].link = nil
                if let file = binderFile(target.relativeString, folder: folder), target.scheme == nil {
                    result[run.range].link = fileLink(file)
                } else if let web = web(target) {
                    result[run.range].link = web
                    if let shown = shown(web), words != web.absoluteString, words != shown {
                        var host = AttributedString(" (\(shown))"); host.foregroundColor = .secondary
                        result.insert(host, at: run.range.upperBound)
                    }
                }
            } else if run.inlinePresentationIntent?.contains(.code) == true, let file = binderFile(words, folder: folder) {
                result[run.range].link = fileLink(file)
            }
        }
        return linkingBareAddresses(result)
    }

    /// `<word>` in a reply is usually a placeholder, and Markdown would otherwise take it for HTML and drop it.
    private static func keepingAngleBrackets(_ text: String) -> String {
        var out = "", inCode = false
        for character in text {
            if character == "`" { inCode.toggle() }
            out += character == "<" && !inCode ? "\\<" : String(character)
        }
        return out
    }

    private static func web(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return scheme == "mailto" || url.host?.isEmpty == false ? url : nil
    }

    private static func shown(_ url: URL) -> String? {
        url.scheme?.lowercased() == "mailto" ? url.absoluteString.dropFirst("mailto:".count).description : url.host
    }

    private static func fileLink(_ file: String) -> URL? {
        var parts = URLComponents(); parts.scheme = fileScheme; parts.path = file
        return parts.url
    }

    private static func linkingBareAddresses(_ text: AttributedString) -> AttributedString {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        var result = text
        let plain = String(result.characters)
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).reversed() {
            // Only an address written out in full: a bare name such as a host shown beside a link stays words.
            guard let url = match.url, url.scheme == "http" || url.scheme == "https", let range = Range(match.range, in: plain),
                  plain[range].lowercased().hasPrefix("http"),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            let span = lower..<upper
            guard result[span].runs.allSatisfy({ $0.link == nil && $0.inlinePresentationIntent?.contains(.code) != true }) else { continue }
            result[span].link = url
        }
        return result
    }

    /// The real path of a file inside the binder that a reply named, or nil. Links can name only what is there, inside.
    static func binderFile(_ named: String, folder: URL?) -> String? {
        guard let folder, !named.isEmpty, named.utf8.count <= 4_096, !named.contains("\n"), !named.hasPrefix("~") else { return nil }
        let plain = (named.split(separator: "#", omittingEmptySubsequences: false).first.map(String.init) ?? named)
        let decoded = plain.removingPercentEncoding ?? plain
        guard let root = realpath(folder.path) else { return nil }
        let joined = decoded.hasPrefix("/") ? decoded : root + "/" + decoded
        guard let real = realpath(joined), real.hasPrefix(root + "/") else { return nil }
        return real
    }

    private static func realpath(_ path: String) -> String? {
        guard let value = Darwin.realpath(path, nil) else { return nil }
        defer { free(value) }
        return String(cString: value)
    }

    /// What a click does. Only links `inline` made reach this, and it checks the file again: it may have gone since.
    static func open(_ url: URL, folder: URL?) -> OpenURLAction.Result {
        if url.scheme == fileScheme {
            if let file = binderFile(url.path, folder: folder) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
            }
            return .handled
        }
        return web(url) == nil ? .discarded : .systemAction
    }
}

/// A reply as it reads: each block on its own line, its links open by click. Long replies stay plain text.
struct ReplyText: View {
    let text: String
    let folder: URL?

    var body: some View {
        Group {
            if text.utf8.count > ReplyMarkdown.longestRendered {
                Text(verbatim: text)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(ReplyMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in view(block) }
                }
            }
        }
        .font(.system(size: 14))
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { [folder] in ReplyMarkdown.open($0, folder: folder) })
    }

    @ViewBuilder private func view(_ block: ReplyMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let words):
            Text(ReplyMarkdown.inline(words, folder: folder))
                .font(.system(size: level == 1 ? 18 : level == 2 ? 16 : 14, weight: .semibold))
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .item(let marker, let depth, let words):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 22, alignment: .trailing)
                Text(ReplyMarkdown.inline(words, folder: folder))
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .paragraph(let words):
            Text(ReplyMarkdown.inline(words, folder: folder))
        case .code(let lines):
            Text(verbatim: lines)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }
}
