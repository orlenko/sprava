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

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public init(binary: URL, repository: URL, key: String, support: URL) {
        self.binary = binary
        self.repository = repository
        self.key = key
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

    /// Writes the key to a private file for one run; the caller deletes it.
    func keyFile() throws -> URL {
        try AtomicFile.makePrivateFolder(runDir)
        let url = runDir.appendingPathComponent(UUID().uuidString)
        try AtomicFile.write(Data((key + "\n").utf8), to: url)
        return url
    }

    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: String
    }

    /// Runs one restic command. `extra` keys are added after the repository and key arguments.
    @discardableResult
    public func run(_ args: [String], cwd: URL? = nil, otherKey: (repo: URL, key: String)? = nil, timeout: TimeInterval? = nil) throws -> Output {
        let keyURL = try keyFile()
        defer { unlink(keyURL.path) }
        var full = args + ["--repo", repository.path, "--password-file", keyURL.path, "--cache-dir", cacheDir.path]
        var otherURL: URL?
        if let other = otherKey {
            let url = runDir.appendingPathComponent(UUID().uuidString)
            try AtomicFile.write(Data((other.key + "\n").utf8), to: url)
            otherURL = url
            full += ["--from-repo", other.repo.path, "--from-password-file", url.path]
        }
        defer { if let otherURL { unlink(otherURL.path) } }
        let task = Process()
        task.executableURL = binary
        task.arguments = full
        task.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "RESTIC_PROGRESS_FPS": "0.2"]
        if let cwd { task.currentDirectoryURL = cwd }
        // stdout is read here to its end; stderr goes to a private file read after restic exits. Nothing waits on a
        // second thread: a reader queued on a dispatch queue may never get one while every cooperative thread is
        // blocked in a call like this, and then every restic run in the process hangs.
        let out = Pipe()
        let errURL = runDir.appendingPathComponent(UUID().uuidString + ".err")
        guard FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure(message: "restic's error output cannot be kept in \(runDir.path)")
        }
        defer { unlink(errURL.path) }
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? err.close() }
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice
        try task.run()
        var killer: DispatchWorkItem?
        if let timeout {
            let k = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: k)
            killer = k
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer?.cancel()
        let stderr = (try? Data(contentsOf: errURL)) ?? Data()
        return Output(status: task.terminationStatus, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))
    }

    func checked(_ args: [String], cwd: URL? = nil, otherKey: (repo: URL, key: String)? = nil, timeout: TimeInterval? = nil) throws -> Output {
        let o = try run(args, cwd: cwd, otherKey: otherKey, timeout: timeout)
        guard o.status == 0 else {
            // restic's messages carry paths, never file contents; keep the first line, short.
            let line = o.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(o.status)"
            throw Failure(message: "restic \(args.first ?? ""): \(line.prefix(200))")
        }
        return o
    }

    // MARK: - Commands

    public func initRepository(copyingParametersFrom other: (repo: URL, key: String)? = nil) throws {
        try AtomicFile.makePrivateFolder(repository.deletingLastPathComponent())
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
                            original: s["original"]?.stringValue)
        }
    }

    public func addTag(_ tag: String, to snapshot: String) throws {
        try checked(["tag", snapshot, "--add", tag, "-q"])
    }

    /// Restores a snapshot's contents into `target`, verifying every restored file; resumable.
    public func restore(_ snapshot: String, into target: URL) throws {
        try checked(["restore", snapshot, "--target", target.path, "--verify", "--overwrite", "if-changed", "-q"])
    }

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

    /// One file of a snapshot, by its path inside the binder ("/documents/deed.pdf").
    public func dump(_ snapshot: String, path: String, to file: URL) throws {
        let o = try checked(["dump", snapshot, path])
        try AtomicFile.write(o.stdout, to: file)
    }

    public func copy(_ snapshot: String, from source: Restic) throws {
        try checked(["copy", snapshot, "-q"], otherKey: (source.repository, source.key))
    }

    public func forget(tag: String, keepLast: Int, keepWithinDays: Int, keepMonthly: Int, keepYearly: Int) throws {
        try checked(["forget", "--tag", tag, "--group-by", "tags", "--keep-last", String(keepLast), "--keep-within", "\(keepWithinDays)d",
                     "--keep-monthly", String(keepMonthly), "--keep-yearly", String(keepYearly), "--keep-tag", "offloaded", "--prune", "-q"])
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
        try checked(["rewrite", "--exclude", pattern, "--forget", "-q"] + snapshots)
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
        try checked(["prune", "-q"])
    }

    public func check(readDataSubset: String? = nil) throws {
        var args = ["check", "-q"]
        if let subset = readDataSubset { args += ["--read-data-subset", subset] }
        try checked(args)
    }
}
