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
        try AtomicFile.makePrivateFolder(spravaDir)
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
        var existing = Data()
        switch SafeFile.read(url, limit: ConversationLimits.monthFileBytes) {
        case .ok(let data): existing = data
        case .missing: break
        case .refused, .unreadable:
            throw Refused(reason: "the conversation history for \(message.month) cannot be read; the message was not saved")
        }
        // A crash's torn group is copied aside, then cut, so the new message never joins it (binder-v0 §7.2.1, §6.9).
        let intact = ConversationHistory.intactLength(of: existing)
        if intact < existing.count {
            let tornDir = spravaDir.appendingPathComponent("torn", isDirectory: true)
            try AtomicFile.makePrivateFolder(tornDir)
            let stamp = ISOTime.string(Date(), timeZone: TimeZone(identifier: "UTC")!).replacingOccurrences(of: ":", with: "")
            try AtomicFile.write(existing[intact...], to: tornDir.appendingPathComponent("conversation-\(message.month)-\(stamp).ndjson"))
            let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw AtomicFile.Failure(step: "open the conversation history", code: errno) }
            defer { close(fd) }
            guard ftruncate(fd, off_t(intact)) == 0 else { throw AtomicFile.Failure(step: "cut the conversation's torn tail", code: errno) }
            try flush(fd, "flush the conversation history")
            existing = existing.prefix(intact)
        }
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

    /// The history folder is private (binder-v0 §7.2): one found readable or writable by others is narrowed first.
    func keepPrivate(_ folder: URL, mode: mode_t) throws {
        var st = stat()
        guard lstat(folder.path, &st) == 0 else { throw AtomicFile.Failure(step: "check the conversation folder", code: errno) }
        guard st.st_mode & 0o077 != 0 else { return }
        guard chmod(folder.path, mode) == 0, lstat(folder.path, &st) == 0, st.st_mode & 0o077 == 0 else {
            throw Refused(reason: "the conversation folder is open to others and could not be made private; the message was not saved")
        }
    }
}
