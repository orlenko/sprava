import CryptoKit
import Foundation
import SpravaKit

/// A binder's instructions: the person's part of its `AGENTS.md`, everything outside Sprava's section between the marker
/// lines (decisions.md F14, D43; docs/binder-instructions.md §2). Read without following a link, within a bound.
public struct BinderInstructions: Sendable, Equatable {
    public static let fileName = "AGENTS.md"
    public static let begin = "<!-- sprava:begin -->"
    public static let end = "<!-- sprava:end -->"
    /// The most of `AGENTS.md` that is read; a larger file is left as it is.
    public static let fileLimit = 1 << 20
    /// The longest person's part the app saves, and the most of it a reader of intake is given (about 4,000 tokens).
    public static let maxCharacters = 16_000
    /// The same bound in UTF-8, since a character can be many bytes.
    public static let maxBytes = 64 * 1024
    /// Sprava's record of the text the person last saved or confirmed in the app, and of the last save's Undo.
    public static let recordPath = ".sprava/instructions.json"
    /// The whole file the last save replaced, kept for its Undo.
    public static let previousPath = ".sprava/instructions-previous.md"

    /// Whether `AGENTS.md` is there.
    public let exists: Bool
    /// Sprava's section as found, from its begin line through its end line and that line's break; empty when there is none.
    public let section: String
    /// The person's part: the text before the begin line, then the text after the end line's break.
    public let text: String
    /// The digest of the text the person last saved or confirmed in the app; nil when none or the record is unreadable.
    public let accepted: String?
    /// The digest the last save left, while its Undo is offered; nil otherwise.
    public let undoAfter: String?

    /// Why `AGENTS.md` is shown but not saved over: each a plain sentence for the page.
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case refused(String)
        case unreadable(String)
        case notText
        case ambiguousMarkers

        public var description: String {
            switch self {
            case .refused(let why): "AGENTS.md cannot be used here (\(why)), so it was left as it is."
            case .unreadable: "AGENTS.md could not be read just now. Try again."
            case .notText: "AGENTS.md is not plain text Sprava can read, so it was left as it is."
            case .ambiguousMarkers: "AGENTS.md has Sprava's marker lines out of order. Fix them in a text editor: one \(BinderInstructions.begin) line, then one \(BinderInstructions.end) line."
            }
        }
    }

    public init(exists: Bool, section: String, text: String, accepted: String? = nil, undoAfter: String? = nil) {
        self.exists = exists
        self.section = section
        self.text = text
        self.accepted = accepted
        self.undoAfter = undoAfter
    }

    /// Whether the person's part is the text the person last saved or confirmed in the app (docs/binder-instructions.md §2):
    /// only then does the reader of new documents follow it.
    public var isAccepted: Bool { accepted == digest }
    /// Whether the last save can be undone now: the person's part is still as that save left it.
    public var canUndo: Bool { undoAfter == digest }
    /// Whether a text fits the bound a save keeps to.
    public static func fits(_ text: String) -> Bool { text.count <= maxCharacters && text.utf8.count <= maxBytes }

    /// The digest the save checks against, so an edit made elsewhere since the page read the file is never overwritten.
    public var digest: String { Self.digest(text) }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The person's part as a reader of intake is given it: trimmed, nil when empty, cut to the bound. Whether it is
    /// accepted is the caller's to check (`isAccepted`).
    public var guidance: (text: String, cut: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !Self.fits(trimmed) else { return (trimmed, false) }
        var cut = String(trimmed.prefix(Self.maxCharacters))
        while cut.utf8.count > Self.maxBytes { cut.removeLast() }
        return (cut, true)
    }

    /// The file holding Sprava's section as found, then `text`. Sprava's section goes first, so the person's text stays
    /// whole and in order wherever the section was found.
    public func contents(with text: String) -> String {
        guard !section.isEmpty else { return text }
        return section + (section.hasSuffix("\n") ? "" : "\n") + text
    }

    /// Splits a file's text into Sprava's section and the person's part. Lines end at LF; a CR before it is kept with the
    /// line, so a file with CRLF keeps its bytes. A marker counts only as a line of its own, spaces aside. A begin line
    /// with no end line after it, a second begin line, or an end line outside a section is ambiguous.
    public static func parse(_ contents: String) -> Result<(section: String, text: String), Problem> {
        var lines: [Substring.UTF8View] = []
        let utf8 = Substring(contents).utf8
        var start = utf8.startIndex
        var at = utf8.startIndex
        while at < utf8.endIndex {
            let next = utf8.index(after: at)
            if utf8[at] == UInt8(ascii: "\n") {
                lines.append(utf8[start..<next])
                start = next
            }
            at = next
        }
        if start < utf8.endIndex { lines.append(utf8[start..<utf8.endIndex]) }

        func marker(_ line: Substring.UTF8View) -> String? {
            let text = String(Substring(line)).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
            return text == begin || text == end ? text : nil
        }
        var beginAt: Int?, endAt: Int?
        for (n, line) in lines.enumerated() {
            switch marker(line) {
            case begin?:
                guard beginAt == nil else { return .failure(.ambiguousMarkers) }
                beginAt = n
            case end?:
                guard beginAt != nil, endAt == nil else { return .failure(.ambiguousMarkers) }
                endAt = n
            default: break
            }
        }
        guard let b = beginAt else { return .success((section: "", text: contents)) }
        guard let e = endAt else { return .failure(.ambiguousMarkers) }
        func joined(_ part: ArraySlice<Substring.UTF8View>) -> String { part.map { String(Substring($0)) }.joined() }
        return .success((section: joined(lines[b...e]), text: joined(lines[..<b]) + joined(lines[(e + 1)...])))
    }

    /// Reads the binder's `AGENTS.md`: from the binder's folder down with no link on the way, a regular file of this user
    /// of at most `fileLimit` bytes, in UTF-8. A missing file is an empty person's part.
    public static func read(_ folder: URL) -> Result<BinderInstructions, Problem> {
        let file = folder.appendingPathComponent(fileName)
        switch SafeFile.read(file, under: folder, limit: fileLimit) {
        case .missing:
            let r = record(folder)
            return .success(BinderInstructions(exists: false, section: "", text: "", accepted: r.accepted, undoAfter: r.undoAfter))
        case .refused(let why): return .failure(.refused(why))
        case .unreadable(let why): return .failure(.unreadable(why))
        case .ok(let data):
            guard let contents = String(data: data, encoding: .utf8) else { return .failure(.notText) }
            let r = record(folder)
            return parse(contents).map {
                BinderInstructions(exists: true, section: $0.section, text: $0.text, accepted: r.accepted, undoAfter: r.undoAfter)
            }
        }
    }

    /// Sprava's record, `{"accepted": digest, "undo_after": digest}`. One missing, unreadable or malformed is empty, so
    /// nothing is followed that the person did not confirm.
    public static func record(_ folder: URL) -> (accepted: String?, undoAfter: String?) {
        guard case .ok(let data) = SafeFile.read(folder.appendingPathComponent(recordPath), under: folder, limit: 64 * 1024),
              let value = try? JSONParser.parse(data).value else { return (nil, nil) }
        func digest(_ key: String) -> String? {
            value[key]?.stringValue.flatMap { $0.wholeMatch(of: /[0-9a-f]{64}/) != nil ? $0 : nil }
        }
        return (digest("accepted"), digest("undo_after"))
    }

    /// An imported binder's old top-level manuals, set aside at import (binder-v0 §9.4 step 2), that the page offers to copy
    /// into the editor for the person to review: name and text, `AGENTS.md` first. Only those there and readable as text.
    public static func oldManuals(_ folder: URL) -> [(name: String, text: String)] {
        ["AGENTS.md", "CLAUDE.md"].compactMap { name in
            let saved = folder.appendingPathComponent(".sprava/adopted/manuals/\(name).saved")
            guard case .ok(let data) = SafeFile.read(saved, under: folder, limit: fileLimit),
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (name, text)
        }
    }
}
