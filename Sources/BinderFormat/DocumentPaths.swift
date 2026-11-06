import CryptoKit
import Darwin
import Foundation

/// The path rules for documents (binder-v0 §4.3): where `file_document` may put a file, and which files it may move.
public enum DocumentPaths {
    static let rootFiles: Set<String> = ["catalog.json", "dashboard.md", "readme.md", "catalog_check.py", "timeline.md"]
    static let manuals: Set<String> = ["claude.md", "claude.local.md", "agents.md", "agents.override.md", "gemini.md"]
    static let reservedFolders: Set<String> = ["intake", "scripts", "ledger", "sources"]
    static let filingOnlyReserved: Set<String> = ["chapters", "entities"]

    /// One segment: non-empty, not starting with `.` or `~`, no backslash, no control or format character.
    static func isSafeSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, !isTooLong(segment, longestName), !segment.hasPrefix("."), !segment.hasPrefix("~"), !segment.contains("\\") else { return false }
        return !segment.unicodeScalars.contains { s in
            let c = s.properties.generalCategory
            return c == .control || c == .format
        }
    }

    package static func fold(_ s: String) -> String {
        // A name longer than any real one is compared as it is: normalizing it could stall (see `longestName`).
        isTooLong(s, 4 * longestName) ? s : s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// The most Unicode scalars of a name these functions normalize. Normalizing takes time that can grow with the
    /// square of a text's length (200,000 combining marks took 27 s; a million U+0F73, which splits into two marks, 16 s),
    /// and a name can come from untrusted input: an email names its attachments as it likes. No file system allows a
    /// name near this long, so a longer one is never normalized: it is refused as a path, taken for a key file so it is
    /// never read, and given a name that says so. Nothing is cut from it, so no part of it is judged without the rest.
    package static let longestName = 1024

    /// The name `safeName` gives a name longer than `longestName`: a key file's, so whatever is attached under it is
    /// held and never read, as `isKeyFile` holds the original. The message it came in stays whole.
    package static let tooLongName = "name too long.key"

    /// Whether `s` has more than `limit` Unicode scalars, counted no further than that.
    static func isTooLong(_ s: String, _ limit: Int) -> Bool { s.unicodeScalars.dropFirst(limit).first != nil }

    /// A path `file_document` may write (`forFiling`), or one `update_document` may record.
    public static func isSafe(_ path: String, forFiling: Bool = true) -> Bool {
        guard !isTooLong(path, 4 * longestName) else { return false }
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
        guard !isTooLong(path, 4 * longestName) else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2, segments[0] == "intake", segments.dropFirst().allSatisfy(isSafeSegment) else { return false }
        if fold(segments[1]) == "mail", let last = segments.last.map(fold), [".env", "state.json"].contains(last) { return false }
        return true
    }

    /// A key or credential file by its name (binder-v0 §3.3): `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa*`,
    /// `id_ecdsa*`, `id_ed25519*`, `*.age`, `age-identity*`, `.netrc`, `credentials*`, `token*.json`, `*.keychain*`,
    /// and a mail puller's `.env` or `.env.*`. Such a file is never read, whatever names it; case is ignored.
    public static func isKeyFile(_ name: String) -> Bool {
        let last = (name as NSString).lastPathComponent
        guard !isTooLong(last, longestName) else { return true }
        let n = fold(last)
        if [".pem", ".key", ".p12", ".pfx", ".age"].contains(where: n.hasSuffix) { return true }
        if ["id_rsa", "id_ecdsa", "id_ed25519", "age-identity", "credentials", ".env."].contains(where: n.hasPrefix) { return true }
        if n == ".netrc" || n == ".env" || n.contains(".keychain") { return true }
        return n.hasPrefix("token") && n.hasSuffix(".json")
    }

    /// A file name made safe as one segment: unsafe characters become `_`, a leading dot or tilde is dropped.
    public static func safeName(_ name: String) -> String {
        guard !isTooLong(name, longestName) else { return tooLongName }
        var out = String.UnicodeScalarView()
        for s in name.precomposedStringWithCanonicalMapping.unicodeScalars {
            let c = s.properties.generalCategory
            out.append(c == .control || c == .format || s == "/" || s == "\\" ? "_" : s)
        }
        var text = String(out)
        text = String(text.drop { $0 == "." || $0 == "~" })
        if manuals.contains(fold(text)) { text = "_" + text }
        return text.isEmpty ? "file" : text
    }

    /// `sha256:`-less lowercase hex of a file, read without following a symbolic link or blocking on a FIFO: the
    /// open never waits for a writer, and anything but a regular file is refused before a byte is read.
    public static func sha256(of url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
    package static func isFreeDestination(_ relative: String, in folder: URL) -> Bool {
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

    /// A plain file of this user at `relative`, read without following a link.
    package static func plainFile(_ relative: String, in folder: URL) -> Bool {
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
