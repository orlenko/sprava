import CryptoKit
import Darwin
import Foundation

/// The path rules for documents (teka-v0 §4.3): where `file_document` may put a file, and which files it may move.
public enum DocumentPaths {
    static let rootFiles: Set<String> = ["catalog.json", "dashboard.md", "readme.md", "catalog_check.py", "timeline.md"]
    static let manuals: Set<String> = ["claude.md", "claude.local.md", "agents.md", "gemini.md"]
    static let reservedFolders: Set<String> = ["intake", "scripts", "ledger", "sources"]
    static let filingOnlyReserved: Set<String> = ["chapters", "entities"]

    /// One segment: non-empty, not starting with `.` or `~`, no backslash, no control or format character.
    static func isSafeSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, !segment.hasPrefix("."), !segment.hasPrefix("~"), !segment.contains("\\") else { return false }
        return !segment.unicodeScalars.contains { s in
            let c = s.properties.generalCategory
            return c == .control || c == .format
        }
    }

    static func fold(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil) }

    /// A path `file_document` may write (`forFiling`), or one `update_document` may record.
    public static func isSafe(_ path: String, forFiling: Bool = true) -> Bool {
        // Compared by scalars: Swift's == treats NFD and NFC as equal.
        guard path.unicodeScalars.elementsEqual(path.precomposedStringWithCanonicalMapping.unicodeScalars), !path.hasPrefix("/") else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.allSatisfy(isSafeSegment) else { return false }
        let folded = segments.map(fold)
        if folded.count == 1, rootFiles.contains(folded[0]) { return false }
        if folded.contains(where: { manuals.contains($0) }) { return false }
        if reservedFolders.contains(folded[0]) { return false }
        if forFiling, filingOnlyReserved.contains(folded[0]) { return false }
        return true
    }

    /// A `from` path: a file under `intake/`, never the mail puller's `.env` or `state.json`.
    public static func isIntake(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2, segments[0] == "intake", segments.dropFirst().allSatisfy(isSafeSegment) else { return false }
        if fold(segments[1]) == "mail", let last = segments.last.map(fold), [".env", "state.json"].contains(last) { return false }
        return true
    }

    /// A file name made safe as one segment: unsafe characters become `_`, a leading dot or tilde is dropped.
    public static func safeName(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        for s in name.precomposedStringWithCanonicalMapping.unicodeScalars {
            let c = s.properties.generalCategory
            out.append(c == .control || c == .format || s == "/" || s == "\\" ? "_" : s)
        }
        var text = String(out)
        while text.hasPrefix(".") || text.hasPrefix("~") { text.removeFirst() }
        if manuals.contains(fold(text)) { text = "_" + text }
        return text.isEmpty ? "file" : text
    }

    /// `sha256:`-less lowercase hex of a file, read without following a symbolic link.
    public static func sha256(of url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }
            hasher.update(data: buffer[0..<n])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every existing component of `relative` under `folder` is a real folder (never a link), and the final
    /// path does not exist yet. Returns false when anything would lead outside the binder.
    static func isFreeDestination(_ relative: String, in folder: URL) -> Bool {
        var url = folder
        let segments = relative.split(separator: "/").map(String.init)
        for (i, segment) in segments.enumerated() {
            url = url.appendingPathComponent(segment)
            var st = stat()
            if lstat(url.path, &st) != 0 { return errno == ENOENT }
            if i == segments.count - 1 { return false }               // the destination exists
            if st.st_mode & S_IFMT != S_IFDIR { return false }       // a link or a file in the way
        }
        return false
    }

    /// Creates the missing parent folders of `relative`, one at a time, refusing links.
    static func makeParents(_ relative: String, in folder: URL) throws {
        var url = folder
        for segment in relative.split(separator: "/").dropLast() {
            url = url.appendingPathComponent(String(segment))
            var st = stat()
            if lstat(url.path, &st) == 0 {
                guard st.st_mode & S_IFMT == S_IFDIR else { throw TekaStore.Refused(reason: "\(segment) is not a folder") }
                continue
            }
            guard mkdir(url.path, 0o755) == 0 || errno == EEXIST else { throw AtomicFile.Failure(step: "create folder", code: errno) }
        }
    }

    /// A plain file of this user at `relative`, read without following a link.
    static func plainFile(_ relative: String, in folder: URL) -> Bool {
        var url = folder
        let segments = relative.split(separator: "/").map(String.init)
        for (i, segment) in segments.enumerated() {
            url = url.appendingPathComponent(segment)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return false }
            if i < segments.count - 1 { guard st.st_mode & S_IFMT == S_IFDIR else { return false } }
            else { return st.st_mode & S_IFMT == S_IFREG && st.st_uid == getuid() }
        }
        return false
    }
}
