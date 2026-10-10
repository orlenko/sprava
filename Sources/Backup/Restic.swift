import CryptoKit
import Darwin
import Foundation
import SpravaKit

/// The bundled restic, run as a subprocess with an explicit environment and no shell (docs/backup.md §10).
/// The key reaches restic through a short-lived 0600 file in Sprava's private folder, never through the
/// environment and never inside a binder.
public struct Restic: Sendable {
    public let binary: URL
    public let repository: URL
    public let key: String
    public let cacheDir: URL
    public let runDir: URL
    /// The executable digest trusted at setup. Checked again immediately before every command, because a long-lived
    /// Restic value can outlive a Homebrew upgrade or another replacement of the file at this path.
    public let expectedSHA256: String?

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public init(binary: URL, repository: URL, key: String, support: URL, expectedSHA256: String? = nil) {
        self.binary = binary
        self.repository = repository
        self.key = key
        self.expectedSHA256 = expectedSHA256 ?? Self.sha256(of: binary)
        cacheDir = support.appendingPathComponent("backup/cache", isDirectory: true)
        runDir = support.appendingPathComponent("backup/run", isDirectory: true)
    }

    /// The restic to run: `SPRAVA_RESTIC`, the copy inside the app bundle, then Homebrew's.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [String] = []
        if let env = environment["SPRAVA_RESTIC"], env.hasPrefix("/") { candidates.append(env) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/restic").path)
        candidates += ["/opt/homebrew/bin/restic", "/usr/local/bin/restic"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// How long restic may go without progress before it is stopped (§3.3: a run is never killed for taking long,
    /// only after a stretch with no progress). The long commands run without `-q`, so they report their progress.
    public static let stallLimit: TimeInterval = 30 * 60

    /// How long a restic asked to stop gets before it is killed, and a killed one before it is given up on.
    var grace: TimeInterval = 5

    /// The clock deadlines and the no-progress cutoff are measured on (`ResticProcess.clock`); tests pass their own.
    var clock: @Sendable () -> TimeInterval = ResticProcess.uptime
    var writeKey: @Sendable (Data, URL) throws -> Void = { try AtomicFile.write($0, to: $1) }
    var diskProgress: @Sendable (pid_t) -> UInt64? = ResticProcess.diskProgress
    var sinkWriterBinary = URL(fileURLWithPath: "/usr/bin/tee")
    var drainLimit: TimeInterval?
    var openOutput: @Sendable (URL, Int32, mode_t) -> Int32 = { open($0.path, $1, $2) }

    /// restic reads its key files as it starts, so a file in the run folder older than this belongs to no run any
    /// more: Sprava stopped (a crash, a power cut) before it could delete it.
    static let staleRunFile: TimeInterval = 15 * 60

    /// Writes the key to a private file for one run; the caller deletes it. Key files earlier runs left behind are
    /// deleted first, so a key never stays on disk past the next run.
    func keyFile(now: Date = Date()) throws -> URL {
        do { try AtomicFile.makePrivateFolder(runDir) }
        catch { throw Failure(message: "restic's private run folder cannot be prepared") }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: runDir.path)) ?? [] {
            let url = runDir.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            if now.timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec) > Self.staleRunFile { unlink(url.path) }
        }
        let url = runDir.appendingPathComponent(UUID().uuidString)
        do { try writeKey(Data((key + "\n").utf8), url) }
        catch { unlink(url.path); throw Failure(message: "restic's password file cannot be prepared") }
        return url
    }

    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: String
    }

    /// Runs one restic command. `extra` keys are added after the repository and key arguments. Nothing waits on restic
    /// without a bound (`ResticProcess`): a run that passes `timeout`, or makes no progress for `stall`, is stopped and
    /// throws. With `stdoutTo`, restic's output goes into that file as it comes, never into memory.
    @discardableResult
    public func run(_ args: [String], cwd: URL? = nil, otherKey: (repo: URL, key: String)? = nil, timeout: TimeInterval? = nil,
                    stall: TimeInterval? = Restic.stallLimit, observeIOAfter marker: String? = nil, stdoutTo file: URL? = nil) throws -> Output {
        guard let expectedSHA256, Self.sha256(of: binary) == expectedSHA256 else {
            throw Failure(message: "restic changed since backup was set up; set it up again to trust the new one")
        }
        let keyURL = try keyFile()
        defer { unlink(keyURL.path) }
        var full = args + ["--repo", repository.path, "--password-file", keyURL.path, "--cache-dir", cacheDir.path]
        var otherURL: URL?
        defer { if let otherURL { unlink(otherURL.path) } }
        if let other = otherKey {
            let url = runDir.appendingPathComponent(UUID().uuidString)
            otherURL = url
            do { try writeKey(Data((other.key + "\n").utf8), url) }
            catch { throw Failure(message: "restic's source password file cannot be prepared") }
            full += ["--from-repo", other.repo.path, "--from-password-file", url.path]
        }
        // stderr goes to a private file, unlinked at once: it is read back through its descriptor, and nothing of it
        // outlives the run.
        let errURL = runDir.appendingPathComponent(UUID().uuidString + ".err")
        let err = openOutput(errURL, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard err >= 0 else { throw Failure(message: "restic's error output cannot be prepared (errno \(errno))") }
        unlink(errURL.path)
        defer { close(err) }
        var sink: Int32?
        if let file {
            let fd = openOutput(file, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw Failure(message: "restic's output destination cannot be opened (errno \(errno))") }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                close(fd)
                throw Failure(message: "restic's output destination is not a regular file")
            }
            sink = fd
        }
        defer { if let sink { close(sink) } }
        var process = ResticProcess(binary: binary, arguments: full,
                                    environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "RESTIC_PROGRESS_FPS": "0.2"],
                                    cwd: cwd, timeout: timeout, stall: stall, observeIOAfter: marker, grace: grace)
        process.clock = clock
        process.diskProgress = diskProgress
        process.sinkWriterBinary = sinkWriterBinary
        process.drainLimit = drainLimit
        let (ending, stdout) = try process.run(stderr: err, sink: sink)
        let command = args.first ?? ""
        let status: Int32
        switch ending {
        case .exited(let code): status = code
        case .stopped(.timedOut): throw Failure(message: "restic \(command) took longer than \(Int(timeout ?? 0)) seconds and was stopped")
        case .stopped(.stalled):
            let span = stall ?? 0
            throw Failure(message: "restic \(command) made no progress for \(span >= 60 ? "\(Int(span / 60)) minutes" : "\(Int(span)) seconds") and was stopped")
        case .stopped(.failedWrite): throw Failure(message: "restic \(command)'s output could not be written, and restic was stopped")
        }
        var stderr = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 14)
        var offset: off_t = 0
        while stderr.count < 1 << 20 {
            let n = buffer.withUnsafeMutableBytes { pread(err, $0.baseAddress, $0.count, offset) }
            guard n > 0 else { break }
            stderr.append(contentsOf: buffer[0..<n])
            offset += off_t(n)
        }
        return Output(status: status, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))
    }

    @discardableResult
    func checked(_ args: [String], cwd: URL? = nil, otherKey: (repo: URL, key: String)? = nil, timeout: TimeInterval? = nil,
                 observeIOAfter marker: String? = nil, stdoutTo file: URL? = nil) throws -> Output {
        let o = try run(args, cwd: cwd, otherKey: otherKey, timeout: timeout, observeIOAfter: marker, stdoutTo: file)
        guard o.status == 0 else {
            // Raw diagnostics may contain binder paths, filenames and account details. Errors reach Health and
            // job logs, so keep only a known category and exit status, never restic's quoted context.
            let diagnostic = o.stderr.lowercased()
            let reason: String
            switch o.status {
            case 10: reason = "the repository is missing or unavailable"
            case 11: reason = "the repository is busy"
            case 12: reason = "the key does not open the repository"
            default:
                if diagnostic.contains("permission denied") { reason = "access was denied" }
                else if diagnostic.contains("no space left") { reason = "the destination has no free space" }
                else { reason = "the operation failed" }
            }
            throw Failure(message: "restic \(args.first ?? ""): \(reason) (exit \(o.status))")
        }
        return o
    }

    // MARK: - Commands

    public func initRepository(copyingParametersFrom other: (repo: URL, key: String)? = nil) throws {
        do { try AtomicFile.makePrivateFolder(repository.deletingLastPathComponent()) }
        catch { throw Failure(message: "restic's repository folder cannot be prepared") }
        var args = ["init", "--repository-version", "2", "-q"]
        if other != nil { args.append("--copy-chunker-params") }
        try checked(args, otherKey: other)
    }

    public func isInitialized() -> Bool {
        FileManager.default.fileExists(atPath: repository.appendingPathComponent("config").path)
            && ((try? run(["cat", "config", "-q"]).status) == 0)
    }

    public struct BackupResult: Sendable, Equatable {
        public let snapshot: String?
        public let bytes: Int64
        public let filesNew: Int
        public let filesChanged: Int
    }

    /// Backs up `folder` from inside it, so the snapshot does not depend on where the folder sits. restic (0.19, macOS)
    /// saves each entry's permission bits and extended attributes (Finder tags and comments, resource forks) by
    /// default, and `restore` writes them back; no `--exclude-xattr` is ever passed (`Backup.manifest` compares them).
    public func backup(_ folder: URL, tags: [String], excludes: [String], skipIfUnchanged: Bool = true) throws -> BackupResult {
        var args = ["backup", ".", "--host", "sprava", "--json", "--pack-size", "64"]
        for t in tags { args += ["--tag", t] }
        for e in excludes { args += ["--exclude", e] }
        if skipIfUnchanged { args.append("--skip-if-unchanged") }
        let o = try checked(args, cwd: folder)
        var result = BackupResult(snapshot: nil, bytes: 0, filesNew: 0, filesChanged: 0)
        for line in o.stdout.split(separator: 0x0A) {
            guard let v = try? JSONParser.parse(Data(line)).value, v["message_type"] == .str("summary") else { continue }
            result = BackupResult(snapshot: v["snapshot_id"]?.stringValue,
                                  bytes: v["total_bytes_processed"]?.numberValue?.safeInteger ?? 0,
                                  filesNew: Int(v["files_new"]?.numberValue?.safeInteger ?? 0),
                                  filesChanged: Int(v["files_changed"]?.numberValue?.safeInteger ?? 0))
        }
        return result
    }

    public struct Snapshot: Sendable, Equatable {
        public let id: String
        public let time: String
        public let tags: [String]
        /// For a snapshot `rewrite` made, the id of the snapshot it replaced (restic's `original`); a copy keeps the
        /// field as it was.
        public var original: String? = nil
        /// The total bytes restic processed, when its snapshot summary carries them.
        public var bytes: Int64? = nil

        /// `time` as a date ("2026-10-09T00:59:52.345658-04:00"; restic writes nanoseconds, which ISO8601DateFormatter
        /// does not read, so the fraction is added apart). Nil when it cannot be read.
        public var date: Date? {
            guard let m = time.wholeMatch(of: /(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)/) else { return nil }
            let f = ISO8601DateFormatter()
            guard let whole = f.date(from: String(m.1) + String(m.3)) else { return nil }
            return whole.addingTimeInterval(m.2.flatMap { Double("0" + $0) } ?? 0)
        }
    }

    public func snapshots(tag: String? = nil) throws -> [Snapshot] {
        var args = ["snapshots", "--json"]
        if let tag { args += ["--tag", tag] }
        let o = try checked(args)
        return (try JSONParser.parse(o.stdout).value.arrayValue ?? []).compactMap { s in
            guard let id = s["id"]?.stringValue else { return nil }
            return Snapshot(id: id, time: s["time"]?.stringValue ?? "", tags: s["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                            original: s["original"]?.stringValue,
                            bytes: s["summary"]?["total_bytes_processed"]?.numberValue?.safeInteger)
        }
    }

    public func addTag(_ tag: String, to snapshot: String) throws {
        try checked(["tag", snapshot, "--add", tag, "-q"])
    }

    /// Removes a retention pin if that exact snapshot still carries it. Restic replaces the snapshot with an
    /// otherwise equivalent one under a new id; callers use this only after no durable record needs the old id.
    /// Looking it up first makes a retry after a partial multi-repository cleanup harmless.
    public func removeTag(_ tag: String, from snapshot: String) throws {
        guard snapshot.wholeMatch(of: /[0-9a-f]{8,64}/) != nil else { throw Failure(message: "restic tag: not a snapshot id") }
        let matches = try snapshots().filter { $0.id.hasPrefix(snapshot) }
        guard matches.count <= 1 else { throw Failure(message: "restic tag: the snapshot id is ambiguous") }
        guard let pinned = matches.first, pinned.tags.contains(tag) else { return }
        try checked(["tag", pinned.id, "--remove", tag, "-q"])
    }

    /// Restores a snapshot's contents into `target`, verifying every restored file; resumable. The no-progress cutoff
    /// holds through verification. After the restoration summary, macOS's per-process disk-I/O counters supply
    /// progress for the otherwise silent verification; a stopped disk read still reaches the stall deadline.
    public func restore(_ snapshot: String, into target: URL) throws {
        try checked(["restore", snapshot, "--target", target.path, "--verify", "--overwrite", "if-changed", "--json"],
                    observeIOAfter: Self.summaryMarker)
    }

    /// What restic's `--json` summary line holds.
    static let summaryMarker = #""message_type":"summary""#

    /// The entries a snapshot holds (files, folders, symbolic links), by their path inside the binder
    /// ("documents/deed.pdf"), as `Backup.manifest` lists a folder.
    public func files(_ snapshot: String) throws -> Set<String> {
        let o = try checked(["ls", snapshot, "--json"])
        var out: Set<String> = []
        for line in o.stdout.split(separator: 0x0A) {
            guard let v = try? JSONParser.parse(Data(line)).value, v["struct_type"] == .str("node"),
                  let path = v["path"]?.stringValue, path.hasPrefix("/") else { continue }
            out.insert(String(path.dropFirst()))
        }
        return out
    }

    /// One file of a snapshot, by its path inside the binder ("/documents/deed.pdf"), written to `file` as restic
    /// reads it, so a large document is never held in memory; `file` appears only once it is whole. The partial file
    /// has a short name of its own, so a document whose name is as long as a name can be still fits.
    public func dump(_ snapshot: String, path: String, to file: URL) throws {
        let part = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString.prefix(8)).part")
        do {
            try checked(["dump", snapshot, path], stdoutTo: part)
            guard rename(part.path, file.path) == 0 else { throw Failure(message: "the document could not be put in place") }
        } catch {
            unlink(part.path)
            throw error
        }
    }

    public func copy(_ snapshot: String, from source: Restic) throws {
        try checked(["copy", snapshot], otherKey: (source.repository, source.key))
    }

    public func forget(tag: String, keepLast: Int, keepWithinDays: Int, keepMonthly: Int, keepYearly: Int, prune: Bool = true) throws {
        var args = ["forget", "--tag", tag, "--group-by", "tags", "--keep-last", String(keepLast), "--keep-within", "\(keepWithinDays)d",
                    "--keep-monthly", String(keepMonthly), "--keep-yearly", String(keepYearly), "--keep-tag", "offloaded"]
        if prune { args.append("--prune") }
        try checked(args)
    }

    /// Rewrites the given snapshots, and only those, without the entry at `path` inside the binder
    /// ("documents/deed.pdf"), and removes the originals (`--forget`; without it restic keeps them, and the entry
    /// with them). A rewrite keeps a snapshot's time and tags and names the snapshot it replaced in `original`, so
    /// `replacements` maps them, also after a rewrite that was cut off. `prune` then removes the data no snapshot
    /// uses any more. No snapshot named does nothing: restic would take that as every snapshot.
    public func rewrite(snapshots: [String], excluding path: String) throws {
        guard !snapshots.isEmpty else { return }
        // Anchored at the snapshot's root, with the pattern characters in the name taken literally.
        let pattern = "/" + path.map { "*?[\\".contains($0) ? "\\\($0)" : String($0) }.joined()
        // Snapshot ids are restic's own hex ids, never options; `run` adds the repository after them.
        guard snapshots.allSatisfy({ $0.wholeMatch(of: /[0-9a-f]{8,64}/) != nil }) else { throw Failure(message: "restic rewrite: not a snapshot id") }
        try checked(["rewrite", "--exclude", pattern, "--forget"] + snapshots)
    }

    /// The snapshots carrying `tag` that replaced one of `before`, by the id they replaced. A snapshot that is itself
    /// one of `before` (left as it was) never counts.
    public func replacements(of before: Set<String>, tag: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for s in try snapshots(tag: tag) where !before.contains(s.id) {
            if let original = s.original, before.contains(original) { out[original] = s.id }
        }
        return out
    }

    public func prune() throws {
        try checked(["prune"])
    }

    public func check(readDataSubset: String? = nil) throws {
        var args = ["check"]
        if let subset = readDataSubset { args += ["--read-data-subset", subset] }
        try checked(args)
    }
}
