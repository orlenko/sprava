import CryptoKit
import Darwin
import Foundation

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
        let out = Pipe(), err = Pipe()
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
        // Read both pipes fully, so a chatty restic never blocks on a full pipe.
        let group = DispatchGroup()
        let errBox = DataBox()
        group.enter()
        DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        task.waitUntilExit()
        killer?.cancel()
        return Output(status: task.terminationStatus, stdout: stdout, stderr: String(decoding: errBox.data, as: UTF8.self))
    }

    final class DataBox: @unchecked Sendable { var data = Data() }

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

    /// Backs up `folder` from inside it, so the snapshot does not depend on where the folder sits.
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
    }

    public func snapshots(tag: String? = nil) throws -> [Snapshot] {
        var args = ["snapshots", "--json"]
        if let tag { args += ["--tag", tag] }
        let o = try checked(args)
        return (try JSONParser.parse(o.stdout).value.arrayValue ?? []).compactMap { s in
            guard let id = s["id"]?.stringValue else { return nil }
            return Snapshot(id: id, time: s["time"]?.stringValue ?? "", tags: s["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }
    }

    public func addTag(_ tag: String, to snapshot: String) throws {
        try checked(["tag", snapshot, "--add", tag, "-q"])
    }

    /// Restores a snapshot's contents into `target`, verifying every restored file; resumable.
    public func restore(_ snapshot: String, into target: URL) throws {
        try checked(["restore", snapshot, "--target", target.path, "--verify", "--overwrite", "if-changed", "-q"])
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

    public func check(readDataSubset: String? = nil) throws {
        var args = ["check", "-q"]
        if let subset = readDataSubset { args += ["--read-data-subset", subset] }
        try checked(args)
    }
}
