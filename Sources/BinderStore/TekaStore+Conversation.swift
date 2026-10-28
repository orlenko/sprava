import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// The conversation history's writer (binder-v0 §7.2.1). It appends a whole message to its month's file under the
/// binder lock, flushed with `F_FULLFSYNC` before it returns, and never replaces an earlier message. Nothing calls it
/// yet: conversation writes stay off until trusted acceptance and expunge exist, and a stored message authenticates
/// nothing by itself.
extension TekaStore {
    var conversationDir: URL { spravaDir.appendingPathComponent("conversation", isDirectory: true) }

    package func appendConversation(_ message: ConversationMessage) throws {
        try withLock { try appendConversationLocked(message) }
    }

    func appendConversationLocked(_ message: ConversationMessage) throws {
        // Members kept as found are checked with bounded work before anything encodes them, so a value too deep or too
        // large for one line is refused instead of exhausting the stack or memory.
        guard Self.fitsOneLine([message.extra] + message.references.map(\.extra)) else {
            throw Refused(reason: "the message was not saved: its extra members are too deep or too large for one line")
        }
        let lines: [Data]
        do { lines = try message.lines() } catch let invalid as ConversationMessage.Invalid {
            throw Refused(reason: "the message was not saved: \(invalid.reason)")
        }
        // Members the caller kept as found may hold a repeated key or an unsafe number, which the reader refuses as
        // damage; such a message is refused here instead of being reported saved (binder-v0 §4.8, §7.2.1).
        for line in lines {
            guard let parsed = try? JSONParser.parse(line.dropLast()), parsed.safety.isSafe else {
                throw Refused(reason: "the message was not saved: it holds unsafe JSON (a repeated member name or a number out of range)")
            }
        }
        let added = lines.reduce(Data(), +)
        // Every folder on the way to the history is private before anything there is created or read: a `.sprava` found
        // open to others (imported, restored) would let another account rename the history away (binder-v0 §7.2).
        try AtomicFile.makePrivateFolder(spravaDir)
        try keepPrivate(spravaDir, mode: 0o700)
        var st = stat()
        let createdFolder = lstat(conversationDir.path, &st) != 0
        if createdFolder {
            guard errno == ENOENT else { throw AtomicFile.Failure(step: "check the conversation folder", code: errno) }
            try AtomicFile.makePrivateFolder(conversationDir)
            try flushFolder(spravaDir, "flush .sprava")
        }
        try checkContainment()
        try keepPrivate(conversationDir, mode: 0o700)

        let url = conversationDir.appendingPathComponent("\(message.month).ndjson")
        let existing = try monthToAppendTo(url, message: message)
        // The whole message fits, or none of it is written.
        let lineCount = existing.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        guard existing.count + added.count <= ConversationLimits.monthFileBytes,
              lineCount + lines.count <= ConversationLimits.monthLines else {
            throw Refused(reason: "this binder's conversation history for \(message.month) is full; the message was not saved")
        }

        let created = lstat(url.path, &st) != 0
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "open the conversation history", code: errno) }
        defer { close(fd) }
        // A file found with wider permissions (imported, restored, edited) is narrowed before anything is added to it.
        try checkSingleLink(fd, message.month)
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw AtomicFile.Failure(step: "check the conversation history", code: errno) }
        if opened.st_mode & 0o077 != 0 {
            guard fchmod(fd, 0o600) == 0, fstat(fd, &opened) == 0, opened.st_mode & 0o077 == 0 else {
                throw Refused(reason: "the conversation history for \(message.month) is readable by others and could not be made private; the message was not saved")
            }
        }
        try writeAll(fd, added)
        try flush(fd, "flush the conversation history")
        if created { try flushFolder(conversationDir, "flush the conversation folder") }
    }

    /// Whether `members` could fit in one history line: nested no deeper than the reader parses, counting the line,
    /// its references and a reference around them, and no longer than a line even before any escaping. The walk
    /// stops at the first bound it passes; every value adds at least one byte, so its work is bounded too.
    static func fitsOneLine(_ members: [JSONObject]) -> Bool {
        let depthLimit = 128 - 3
        var bytes = 0
        var pending: [(value: JSONValue, depth: Int)] = members.map { (.object($0), 1) }
        while let (value, depth) = pending.popLast() {
            guard depth <= depthLimit else { return false }
            switch value {
            case .null, .bool: bytes += 4
            case .number(let n): bytes += n.description.utf8.count
            case .string(let s): bytes += s.utf8.count + 2
            case .array(let a):
                bytes += 2
                pending.append(contentsOf: a.map { ($0, depth + 1) })
            case .object(let o):
                bytes += 2
                for entry in o.entries {
                    bytes += entry.key.utf8.count + 3
                    pending.append((entry.value, depth + 1))
                }
            }
            guard bytes <= ConversationLimits.lineBytes else { return false }
        }
        return true
    }

    /// The month as it may be appended to: missing, or a file the one safe reader reads whole (binder-v0 §7.2.1). The
    /// reader decides before anything changes, so its bounds hold here too: a month over its size or line limits, with
    /// an oversized line, or with damage anywhere but a crash's torn tail is refused and left for repair. That tail is
    /// copied to `.sprava/torn/` and cut, so the new message never joins it. A message id already in the month is
    /// refused, since the reader would hide the new message as damage.
    func monthToAppendTo(_ url: URL, message: ConversationMessage) throws -> Data {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            guard errno == ENOENT else { throw AtomicFile.Failure(step: "check the conversation history", code: errno) }
            return Data()
        }
        // Checked on the path before the file is read or copied anywhere (races with another program are out of scope,
        // architecture 1).
        guard st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else {
            throw Refused(reason: "the conversation history for \(message.month) is linked to another file; the message was not saved")
        }
        let unreadable = Refused(reason: "the conversation history for \(message.month) cannot be read; the message was not saved")
        guard case .month(let month) = ConversationHistory.read(month: message.month, in: folder),
              case .ok(var existing) = SafeFile.read(url, limit: ConversationLimits.monthFileBytes) else { throw unreadable }
        let intact = ConversationHistory.intactLength(of: existing)
        let intactLines = existing.prefix(intact).reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        // Only a crash's tail is cut: a torn line, and the parts of one message written before it. Damage of any other
        // kind stays where it is, even at the end, for the person's repair.
        guard month.damage.allSatisfy({ $0.lines.lowerBound > intactLines && [.torn, .missingPart].contains($0.reason) }) else {
            throw Refused(reason: "the conversation history for \(message.month) has damaged lines to repair first; the message was not saved")
        }
        guard !month.messages.contains(where: { $0.id == message.id }) else {
            throw Refused(reason: "a message with this id is already in the history for \(message.month); the message was not saved")
        }
        guard intact < existing.count else { return existing }
        // The copy is the only one of those bytes once the month is cut: its folder is made durable and private first
        // (`.sprava` already is), so neither a power loss nor another account can take it (binder-v0 §7.2).
        let tornDir = spravaDir.appendingPathComponent("torn", isDirectory: true)
        let createdTorn = lstat(tornDir.path, &st) != 0
        try AtomicFile.makePrivateFolder(tornDir)
        if createdTorn { try flushFolder(spravaDir, "flush .sprava") }
        try keepPrivate(tornDir, mode: 0o700)
        let stamp = ISOTime.string(Date(), timeZone: TimeZone(identifier: "UTC")!).replacingOccurrences(of: ":", with: "")
        try Self.keepAside(existing[intact...], in: tornDir, named: "conversation-\(message.month)-\(stamp)")
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "open the conversation history", code: errno) }
        defer { close(fd) }
        try checkSingleLink(fd, message.month)
        guard ftruncate(fd, off_t(intact)) == 0 else { throw AtomicFile.Failure(step: "cut the conversation's torn tail", code: errno) }
        try flush(fd, "flush the conversation history")
        existing = existing.prefix(intact)
        return existing
    }

    /// Writes a torn tail under a name no file has yet, created exclusively and flushed, so an earlier copy is never
    /// replaced (binder-v0 §7.2: `torn/` is not rebuildable).
    static func keepAside(_ bytes: Data, in folder: URL, named stem: String) throws {
        for attempt in 0..<100 {
            let name = attempt == 0 ? "\(stem).ndjson" : "\(stem)-\(attempt).ndjson"
            let fd = open(folder.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0, errno == EEXIST { continue }
            guard fd >= 0 else { throw AtomicFile.Failure(step: "keep the torn conversation aside", code: errno) }
            defer { close(fd) }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 { if errno == EINTR { continue }; throw AtomicFile.Failure(step: "keep the torn conversation aside", code: errno) }
                    offset += n
                }
            }
            try AtomicFile.flushToDisk(fd, step: "flush the torn conversation")
            try AtomicFile.flushFolder(folder, step: "flush the torn folder")
            return
        }
        throw Refused(reason: "the torn part of the conversation history could not be kept aside; the message was not saved")
    }

    /// A month file hard-linked elsewhere (an imported or restored binder) would carry every write to the other path
    /// too, the catalog among them; it is refused before anything changes.
    func checkSingleLink(_ fd: Int32, _ month: String) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw AtomicFile.Failure(step: "check the conversation history", code: errno) }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else {
            throw Refused(reason: "the conversation history for \(month) is linked to another file; the message was not saved")
        }
    }

    /// The history's folders are private (binder-v0 §7.2): one found readable or writable by others is narrowed first.
    func keepPrivate(_ folder: URL, mode: mode_t) throws {
        var st = stat()
        guard lstat(folder.path, &st) == 0 else { throw AtomicFile.Failure(step: "check the conversation folder", code: errno) }
        guard st.st_mode & 0o077 != 0 else { return }
        guard chmod(folder.path, mode) == 0, lstat(folder.path, &st) == 0, st.st_mode & 0o077 == 0 else {
            throw Refused(reason: "a folder of the conversation history is open to others and could not be made private; the message was not saved")
        }
    }
}
