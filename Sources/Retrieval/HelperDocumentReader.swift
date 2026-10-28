import BinderFormat
import Darwin
import Extract
import Foundation
import SpravaKit

/// Reads a binder's documents for the index through the sandboxed helper (architecture 2.1), from the binder
/// folder down with no link anywhere on the way. The helper gives a document's text as one block, so its passages
/// carry no page number and the coverage says so, unless the document has one page; a page-by-page reading is
/// the helper's to add.
public struct HelperDocumentReader: DocumentReader {
    public let binder: URL
    public let reader: ExtractHelper.Reader

    public init(binder: URL, reader: ExtractHelper.Reader) {
        self.binder = binder
        self.reader = reader
    }

    public func revision(of document: DocumentRecord) -> String? {
        guard case .ok(let data) = bytes(document.path) else { return nil }
        return data.sha256Hex
    }

    public func read(_ document: DocumentRecord) -> DocumentText {
        let data: Data
        switch bytes(document.path) {
        case .ok(let d): data = d
        case .refused(let why): return DocumentText(revision: "", language: "und", pages: [], problem: "the file was not opened: it is \(why)")
        case .missing: return DocumentText(revision: "", language: "und", pages: [], problem: "the file is not there")
        case .unreadable(let why): return DocumentText(revision: "", language: "und", pages: [], problem: "the file cannot be read now (\(why))")
        }
        let name = (document.path as NSString).lastPathComponent
        let result: Extractor.Result
        // A reader that failed (missing, stopped, timed out) is tried again at the next refresh: no revision is kept.
        do { result = try ExtractHelper.run(data, name: name, reader: reader) } catch {
            return DocumentText(revision: "", language: "und", pages: [], problem: "\(error)")
        }
        if let problem = result.problem { return DocumentText(revision: data.sha256Hex, language: "und", pages: [], problem: problem) }
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let number: Int? = (result.pages ?? 1) == 1 ? 1 : nil
        var notes: [String] = []
        if let email = result.email {
            // Reply drafting needs the message's identity, not just its body. These are untrusted source
            // fields, never instructions or permission to send. Bound each field independently.
            let headers = [("From", email.from), ("To", email.to), ("Subject", email.subject),
                           ("Date", email.date), ("Message-ID", email.messageID)]
            var lines: [String] = []
            for (name, value) in headers {
                guard let value, !value.isEmpty else { continue }
                lines.append(name + ": " + String(String.UnicodeScalarView(value.unicodeScalars.prefix(4_096))))
                if value.unicodeScalars.count > 4_096 { notes.append("the \(name) header was shortened") }
            }
            if !lines.isEmpty { text = lines.joined(separator: "\n") + "\n\n" + text }
        }
        if let attachments = result.email?.attachments, !attachments.isEmpty { notes.append("\(attachments.count) attachment(s) are not indexed with the message") }
        return DocumentText(revision: data.sha256Hex, language: IntakeReading.language(of: text),
                            pages: [(number, text.isEmpty ? .illegible : .read(text, from: result.textFrom))], notes: notes)
    }

    /// The document's bytes, opened from the binder down without following a link, within the reader's size limit.
    func bytes(_ path: String) -> SafeFile.Outcome {
        guard BinderIndex.excluded(path) == nil else { return .refused("in a place Sprava never reads") }
        let dir = Darwin.open(binder.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { return SafeFile.openFailure(errno) }
        defer { Darwin.close(dir) }
        var fd: Int32
        repeat { fd = openat(dir, path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK) } while fd < 0 && errno == EINTR
        guard fd >= 0 else { return SafeFile.openFailure(errno) }
        defer { Darwin.close(fd) }
        return SafeFile.read(fd: fd, limit: Extractor.Limits().bytes)
    }
}
