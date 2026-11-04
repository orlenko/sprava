import BinderFormat
import CryptoKit
import Foundation
import Shelf
import SpravaKit

/// The same email filed before (D39): the same Message-ID, From and Date, the same fields saying how it reads (Subject,
/// MIME-Version, Content-Type, Content-Transfer-Encoding), each compared byte for byte, and the same body byte for byte,
/// its line endings evened out only where they carry no data (`lineEndingsCarryNoData`); nothing else is ever rewritten.
/// A copy fetched or saved again keeps all of them. Anyone who received an email knows its header, and From proves
/// nothing, so a message that only copies it, with another body, gets its card. A message is read here, not in the
/// helper: a plain file of this user, never through a link, at most 32 MiB, its header ending within 64 KiB. The header
/// is untrusted, so a field that is needed and missing, given twice, too long or
/// holding a control character, or an id holding a space, gives no key: such a message is judged by its exact bytes alone.
///
/// The cost: while any message in intake has a key, every filed `.eml` is read whole on each pass, off the command queue.
extension IntakeWatcher {
    /// How much of a message may hold its header.
    static let headerLimit = 64 * 1024
    /// The largest message read for its key.
    static let messageLimit = 32 * 1024 * 1024
    /// The longest line RFC 5322 allows, and so the longest field value kept.
    static let messageIDLimit = 998

    /// The files of a thing in intake that are the message itself: a dropped `.eml`, or an imported message's original
    /// beside its text. Another `.eml` in its attachments folder is a message it carries, not this one.
    static func messageFiles(of candidate: Candidate) -> [String] {
        ([candidate.name] + candidate.attachments).filter { name in
            guard !DocumentPaths.isKeyFile(name) else { return false }
            return name == candidate.name ? (name as NSString).pathExtension.lowercased() == "eml"
                : (name as NSString).lastPathComponent == mailOriginalName
        }
    }

    /// The keys filed emails hold now, read from each filed `.eml` itself: a filed message edited (its header or its
    /// body), or gone, no longer matches, as a document edited after filing never hides a copy.
    static func filedMessageKeys(_ row: ShelfRow) -> Set<String> {
        var out = Set<String>()
        for path in filedPaths(row) where (path as NSString).pathExtension.lowercased() == "eml" {
            if let key = messageKey(of: row.folder.appendingPathComponent(path)) { out.insert(key) }
        }
        return out
    }

    /// The key of the message in a file, or nil.
    static func messageKey(of url: URL) -> String? {
        guard case .ok(let data) = SafeFile.read(url, limit: messageLimit) else { return nil }
        return messageKey(message: data)
    }

    /// The key of a whole message, or nil.
    static func messageKey(message data: Data) -> String? {
        guard let (header, body) = splitMessage(data) else { return nil }
        return messageKey(header: header, body: body, evenLineEndings: lineEndingsCarryNoData(data))
    }

    /// Whether a message's line endings carry no data, so CRLF and LF may be taken as one: every CR in it ends a line
    /// (none stands alone), and nothing in it, a header or any part's header, declares the `binary` transfer encoding,
    /// whose bytes are all data. Under 7bit, 8bit, quoted-printable or base64 a line break is CRLF by definition, and a
    /// CR that is data is encoded, so saving the message with other line endings changes nothing it says. Any line naming
    /// that field with `binary` in its value counts, wherever it is: a doubt keeps the bytes exact.
    static func lineEndingsCarryNoData(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        for (i, b) in bytes.enumerated() where b == 0x0D && (i + 1 == bytes.count || bytes[i + 1] != 0x0A) { return false }
        let name = Array("content-transfer-encoding".utf8)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var inField = false
        for line in lines {
            let folded = line.first == 0x20 || line.first == 0x09
            if !folded {
                // Only a line starting with the field's name, any case, is read further.
                let start = line.prefix(name.count).map { $0 | 0x20 }
                inField = line.count > name.count && start.elementsEqual(name)
            }
            guard inField else { continue }
            let text = String(decoding: line, as: UTF8.self).lowercased().filter { !$0.isWhitespace }
            if text.contains("binary") { return false }
        }
        return true
    }

    /// A message's header and body, split at its first empty line (LF or CRLF). With no empty line, a file shorter than
    /// the header limit is all header; a longer one is nothing.
    static func splitMessage(_ data: Data) -> (Data, Data)? {
        let bytes = [UInt8](data.prefix(headerLimit + 3))
        if bytes.first == 0x0A { return (Data(), data.dropFirst(1)) }
        if bytes.starts(with: [0x0D, 0x0A]) { return (Data(), data.dropFirst(2)) }
        var i = 0
        while i < bytes.count, i < headerLimit {
            if bytes[i] == 0x0A {
                var j = i + 1
                if j < bytes.count, bytes[j] == 0x0D { j += 1 }
                if j < bytes.count, bytes[j] == 0x0A { return (data.prefix(i), data.dropFirst(j + 1)) }
            }
            i += 1
        }
        return data.count < headerLimit ? (data, Data()) : nil
    }

    /// The fields that must be there, once each, for a message to have a key.
    static let requiredFields = ["message-id", "from", "date"]
    /// The fields that say what the message reads as: equal when both lack one, never when only one does.
    static let shownFields = ["subject", "mime-version", "content-type", "content-transfer-encoding"]

    /// What makes a message the same email, as a digest: its Message-ID, From and Date, the fields that say how its body
    /// reads (`shownFields`), each byte for byte, and its body's digest: of its exact bytes, or with CRLF as LF when
    /// `evenLineEndings`, which the key also holds, so a body read one way never matches one read the other. Nil unless
    /// the three it needs are there, none of these fields is given twice, and each passes its checks.
    static func messageKey(header: Data, body: Data, evenLineEndings: Bool) -> String? {
        let values = fields(Set(requiredFields + shownFields), inHeader: header)
        guard values.values.allSatisfy({ $0.count == 1 }),
              let id = values["message-id"]?.first.flatMap(normalizedMessageID) else { return nil }
        var parts: [[UInt8]] = [id]
        for name in requiredFields.dropFirst() {
            guard let value = values[name]?.first.flatMap({ normalizedField($0) }) else { return nil }
            parts.append(value)
        }
        // A field missing is told apart from one left empty by the byte before it.
        for name in shownFields {
            guard let raw = values[name]?.first else { parts.append([1]); continue }
            guard let value = normalizedField(raw, emptyAllowed: true) else { return nil }
            parts.append([2] + value)
        }
        // No field holds a NUL, so each ends where its NUL is.
        var hasher = SHA256()
        for part in parts { hasher.update(data: part + [0]) }
        hasher.update(data: [evenLineEndings ? 1 : 0])
        // With line endings evened, every CR ends a line, so dropping each makes CRLF an LF and changes nothing else.
        let digest = evenLineEndings ? SHA256.hash(data: body.filter { $0 != 0x0D }) : SHA256.hash(data: body)
        hasher.update(data: Data(digest))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The one Message-ID field of a header, as an id. Nil when there is no such field or more than one.
    static func messageID(inHeader data: Data) -> [UInt8]? {
        guard let values = fields(["message-id"], inHeader: data)["message-id"], values.count == 1 else { return nil }
        return normalizedMessageID(values[0])
    }

    /// The fields of a header with these lowercased names, as their bytes, unfolded (the line breaks dropped, the space
    /// kept), every time each is given. Lines end at LF only, with a CR before it dropped; any other byte, 8-bit ones
    /// included, stays as it is, so two values are equal only when their bytes are.
    static func fields(_ names: Set<String>, inHeader data: Data) -> [String: [[UInt8]]] {
        var values: [String: [[UInt8]]] = [:]
        var current: String?
        for part in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var line = [UInt8](part)
            if line.last == 0x0D { line.removeLast() }
            if line.first == 0x20 || line.first == 0x09 {
                if let name = current, var list = values[name] { list[list.count - 1] += line; values[name] = list }
                continue
            }
            current = nil
            guard let colon = line.firstIndex(of: 0x3A) else { continue }
            let name = String(decoding: line[..<colon], as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
            guard names.contains(name) else { continue }
            values[name, default: []].append(Array(line[(colon + 1)...]))
            current = name
        }
        return values
    }

    static func trimmed(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        let space: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 }
        guard let first = bytes.firstIndex(where: { !space($0) }), let last = bytes.lastIndex(where: { !space($0) }) else { return [] }
        return bytes[first...last]
    }

    /// Whether a value holds a control or direction character: an ASCII control byte (a tab aside, when `tab`), or one
    /// in what its bytes say as UTF-8.
    static func holdsControl(_ bytes: ArraySlice<UInt8>, tab: Bool) -> Bool {
        if bytes.contains(where: { ($0 < 0x20 && !(tab && $0 == 0x09)) || $0 == 0x7F }) { return true }
        return String(decoding: bytes, as: UTF8.self).unicodeScalars.contains { s in
            s != "\t" && (s.properties.generalCategory == .control || s.properties.generalCategory == .format)
        }
    }

    /// A field's value, trimmed and compared byte for byte: never longer than a line may be, or holding a control or
    /// direction character (a tab left by folding aside), and empty only when `emptyAllowed`.
    static func normalizedField(_ raw: [UInt8], emptyAllowed: Bool = false) -> [UInt8]? {
        let value = trimmed(raw)
        guard emptyAllowed || !value.isEmpty, value.count <= messageIDLimit, !holdsControl(value, tab: true) else { return nil }
        return Array(value)
    }

    /// An id as RFC 5322 writes one, `<left@right>`, with a comment after it ignored; brackets may be missing.
    static func normalizedMessageID(_ raw: [UInt8]) -> [UInt8]? {
        var id = trimmed(raw)
        if id.first == 0x3C {
            guard let close = id.firstIndex(of: 0x3E) else { return nil }
            id = id[(id.startIndex + 1)..<close]
        }
        guard id.count <= messageIDLimit, let at = id.firstIndex(of: 0x40), at != id.startIndex, at != id.endIndex - 1,
              !id.contains(where: { $0 <= 0x20 || $0 == 0x3C || $0 == 0x3E }), !holdsControl(id, tab: false),
              !String(decoding: id, as: UTF8.self).unicodeScalars.contains(where: \.properties.isWhitespace) else { return nil }
        return Array(id)
    }
}
