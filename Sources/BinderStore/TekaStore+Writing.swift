import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// The write protocol (binder-v0 §4.9, §6.9): the temporary catalog, the op log append, the filed files' moves
/// and the flushes that make each step durable.
extension TekaStore {
    /// The files a batch files (binder-v0 §4.3, §6.9 step 4). A move out of `intake/` needs the source to be a plain
    /// file with the recorded digest, so a file that changed or is gone since the card was made is refused; the
    /// destination must be free and lie inside the binder. A filing without `from` needs the file in place. A key or
    /// credential file is never read or moved, at either end (binder-v0 §3.3). An `update_document` that sets a path
    /// needs the file there, reached without a link, or filed earlier in the batch.
    func prepareMoves(_ lines: [JSONObject]) throws -> [(from: String, to: String, sha: String)] {
        var moves: [(String, String, String)] = []
        var claimed = Set<String>()
        for line in lines where line["op"] == .str("update_document") {
            guard let path = line["args"]?["set"]?["path"] else { continue }
            guard let p = path.stringValue, DocumentPaths.isSafe(p, forFiling: false) else { throw Refused(reason: "a document's new path breaks the path rules") }
            let filedHere = lines.contains { $0["op"] == .str("file_document") && $0["args"]?["document"]?["path"]?.stringValue.map(DocumentPaths.fold) == DocumentPaths.fold(p) }
            guard filedHere || DocumentPaths.plainFile(p, in: folder) else {
                throw Refused(reason: "no file is at \(p), or the way there is not a plain folder")
            }
        }
        for line in lines where line["op"] == .str("file_document") {
            let args = line["args"]?.objectValue ?? JSONObject()
            guard let path = args["document"]?["path"]?.stringValue, let sha = args["document"]?["sha256"]?.stringValue else { continue }
            if DocumentPaths.isKeyFile(path) || args["from"]?.stringValue.map(DocumentPaths.isKeyFile) == true {
                throw Refused(reason: "a key or credential file is never filed")
            }
            guard claimed.insert(DocumentPaths.fold(path)).inserted else { throw Refused(reason: "two documents would be filed at \(path)") }
            if let from = args["from"]?.stringValue {
                guard DocumentPaths.plainFile(from, in: folder),
                      DocumentPaths.sha256(of: folder.appendingPathComponent(from)) == sha else {
                    throw Refused(reason: "the file in intake/ changed or is gone since the card was made")
                }
                guard DocumentPaths.isFreeDestination(path, in: folder) else {
                    throw Refused(reason: "a file already exists at \(path), or the way there is not a plain folder")
                }
                moves.append((from, path, sha))
            } else {
                guard DocumentPaths.plainFile(path, in: folder), DocumentPaths.sha256(of: folder.appendingPathComponent(path)) == sha else {
                    throw Refused(reason: "the document is not at \(path) with the recorded digest")
                }
            }
        }
        return moves
    }

    /// Step 4: each move is a rename that never replaces a file, from a file under `intake/` to a path the filing
    /// rules allow (binder-v0 §4.3), whoever asks for it: a logged move recovery finishes is held to the same rules.
    package func performMoves(_ moves: [(from: String, to: String, sha: String)]) throws {
        for move in moves {
            guard DocumentPaths.isIntake(move.from), DocumentPaths.isSafe(move.to) else {
                throw Refused(reason: "a file is moved only from intake/ to a path inside the binder")
            }
            // Checked again right before the rename: the source is still a plain file, the way there has no link.
            guard !DocumentPaths.isKeyFile(move.from), !DocumentPaths.isKeyFile(move.to),
                  DocumentPaths.plainFile(move.from, in: folder), DocumentPaths.isFreeDestination(move.to, in: folder),
                  DocumentPaths.sha256(of: folder.appendingPathComponent(move.from)) == move.sha else {
                throw Refused(reason: "the file in intake/ or its destination changed while it was being filed")
            }
            try DocumentPaths.makeParents(move.to, in: folder)
            let source = folder.appendingPathComponent(move.from).path
            let target = folder.appendingPathComponent(move.to).path
            guard renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 else {
                throw AtomicFile.Failure(step: "move \(move.from)", code: errno)
            }
        }
        for dir in Set(moves.flatMap { [($0.from as NSString).deletingLastPathComponent, ($0.to as NSString).deletingLastPathComponent] }) {
            try flushFolder(folder.appendingPathComponent(dir), "flush the folder of a filed file")
        }
    }

    /// Steps 4 to 7 of the write protocol and steps 3 to 6 of binder-v0 §6.9.
    func write(catalog: JSONObject, appending lines: [JSONObject], expectedHash: String,
               moves: [(from: String, to: String, sha: String)] = []) throws {
        // Every catalog Sprava writes passes here: never one its own reader would refuse (binder-v0 §4.8).
        guard !TransactionGuard.isUnsafeJSON(.object(catalog)) else {
            throw Refused(reason: "the catalog would hold unsafe JSON (a number out of range or a repeated member name); nothing was written")
        }
        let text = JSONWriter.pretty(.object(catalog))
        let temp = folder.appendingPathComponent(".\(UUID().uuidString.lowercased()).tmp")
        // The new catalog is private while it is written and then takes the found catalog's permissions, so a change
        // never makes a private catalog readable to others.
        var st = stat()
        let mode = lstat(catalogURL.path, &st) == 0 ? st.st_mode & 0o777 : 0o600
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "create temp catalog", code: errno) }
        var renamed = false
        defer { if !renamed { unlink(temp.path) } }
        do {
            defer { close(fd) }
            try writeAll(fd, Data(text.utf8))
            guard fchmod(fd, mode) == 0 else { throw AtomicFile.Failure(step: "set the temp catalog's permissions", code: errno) }
            try flush(fd, "flush temp catalog")
        }

        // Step 5: someone changed the file without the lock; start over.
        let (_, nowHash, _) = try readCatalog()
        guard nowHash == expectedHash else { throw ChangedWhileWriting() }

        try appendLines(lines)
        // The log flush is the slowest step: hash once more, and if the file changed meanwhile, abort the batch so
        // the next pass records the edit and applies the batch on top of it (architecture 4.2 step 9).
        if !lines.isEmpty {
            try testHookAfterAppend?()
            let (_, againHash, _) = try readCatalog()
            if againHash != expectedHash {
                var abort = JSONObject()
                abort.set("id", .string(UUIDv7.make()))
                abort.set("at", .string(ISOTime.string(Date(), timeZone: TimeZone(identifier: "UTC")!)))
                abort.set("actor", .obj([("kind", .str("import")), ("client", .string(client))]))
                abort.set("before_hash", .string(expectedHash))
                abort.set("after_hash", .string(expectedHash))
                abort.set("op", .str("abort"))
                abort.set("args", .obj([("ops", .array(lines.compactMap { $0["id"] })),
                                        ("reason", .str("the catalog was edited outside while this change was written"))]))
                try appendLines([abort])
                throw ChangedWhileWriting()
            }
        }
        // A crash or failure from here on is rolled forward on the next read (binder-v0 §6.7 step 3, §6.9).
        try performMoves(moves)
        // Moving takes time (each file is hashed again and its folders flushed): an edit made meanwhile is never written
        // over. The next pass finds the snapshot at this write's start, aborts the write, puts the files back and
        // records the edit (binder-v0 §6.7 step 5), and a batch is then applied again on top of it.
        if !moves.isEmpty {
            try testHookAfterMoves?()
            let (_, movedHash, _) = try readCatalog()
            guard movedHash == expectedHash else { throw ChangedWhileWriting() }
        }
        guard rename(temp.path, catalogURL.path) == 0 else { throw AtomicFile.Failure(step: "rename catalog", code: errno) }
        renamed = true
        try flushFolder(folder, "flush the binder folder")
        try AtomicFile.write(Data(text.utf8), to: snapshotURL)
    }

    func appendLines(_ lines: [JSONObject]) throws {
        // Every op line passes here: never one the op log's reader would refuse (binder-v0 §4.8).
        guard !lines.contains(where: { TransactionGuard.isUnsafeJSON(.object($0)) }) else {
            throw Refused(reason: "an op would hold unsafe JSON (a number out of range or a repeated member name); nothing was written")
        }
        try AtomicFile.makePrivateFolder(spravaDir)
        // A torn tail, or a trailing batch shorter than its size, is copied aside and cut before the next append
        // (binder-v0 §6.9).
        if let data = try? Data(contentsOf: opLogURL), let cut = Self.validLength(of: data), cut < data.count {
            let tornDir = spravaDir.appendingPathComponent("torn", isDirectory: true)
            try AtomicFile.makePrivateFolder(tornDir)
            let stamp = ISOTime.string(Date(), timeZone: TimeZone(identifier: "UTC")!).replacingOccurrences(of: ":", with: "")
            try AtomicFile.write(data[cut...], to: tornDir.appendingPathComponent("\(stamp).ndjson"))
            // Appending after a tail that could not be cut would join it to the new lines.
            let fd = open(opLogURL.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw AtomicFile.Failure(step: "open op log", code: errno) }
            defer { close(fd) }
            guard ftruncate(fd, off_t(cut)) == 0 else { throw AtomicFile.Failure(step: "cut the op log's torn tail", code: errno) }
        }
        let fd = open(opLogURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "open op log", code: errno) }
        defer { close(fd) }
        let text = lines.map { JSONWriter.compact(.object($0)) + "\n" }.joined()
        try writeAll(fd, Data(text.utf8))
        try flush(fd, "flush op log")
    }

    /// Flushes a file to stable storage with `F_FULLFSYNC` (binder-v0 §6.9 step 3), by SpravaKit's one flush rule
    /// (`AtomicFile.flushToDisk`): any failure but an unsupported volume's throws, so no later step builds on a
    /// change that may not have reached the disk.
    func flush(_ fd: Int32, _ step: String) throws {
        if testHookFlushFails?(step) == true { throw AtomicFile.Failure(step: step, code: EIO) }
        try AtomicFile.flushToDisk(fd, step: step, fullSync: testHookFullSync ?? { fcntl($0, F_FULLFSYNC) })
    }

    /// Flushes a folder, so a rename or a move in it survives a power loss (binder-v0 §4.9 step 7). A folder that
    /// cannot be opened or flushed fails the write (`AtomicFile.flushFolder`).
    func flushFolder(_ url: URL, _ step: String) throws {
        let failing = testHookFlushFails?(step) == true
        try AtomicFile.flushFolder(url, step: step, fullSync: { fd in
            if failing { errno = EIO; return -1 }
            return (self.testHookFullSync ?? { fcntl($0, F_FULLFSYNC) })(fd)
        })
    }

    /// The byte length of the op log's part that took effect: complete lines, minus a trailing batch with fewer
    /// lines than its `batch_size`.
    static func validLength(of data: Data) -> Int? {
        guard !data.isEmpty else { return nil }
        var end = data.last == 0x0A ? data.count : (data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0)
        // Walk back over the last complete lines while they belong to one batch.
        var starts: [Int] = []
        var i = end
        var batch: String?
        var size: Int64?
        while i > 0 {
            let lineEnd = i - 1   // the newline
            let lineStart = data[..<lineEnd].lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            guard let v = try? JSONParser.parse(data[lineStart..<lineEnd]).value, case .string(let b)? = v["batch"] else { break }
            if batch == nil {
                batch = b
                size = v["batch_size"]?.numberValue?.safeInteger
            } else if b != batch { break }
            starts.append(lineStart)
            i = lineStart
        }
        if let size, let first = starts.last, Int64(starts.count) < size { end = first }
        return end
    }

    func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AtomicFile.Failure(step: "write", code: errno)
                }
                offset += n
            }
        }
    }
}
