import Darwin
import Foundation
import SpravaKit

extension Backup {
    /// Own state databases live directly in the support folder or an owning target's immediate folder (A13).
    /// Captures and unfiled documents are payloads; an attachment called .sqlite remains an ordinary attachment.
    private static func stateDatabase(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/")
        return parts.count <= 2 && relative.hasSuffix(".sqlite")
            && !["Captures", "unfiled"].contains(parts.first.map(String.init) ?? "")
    }

    /// Copies state into a private staging folder before restic runs. SQLite's online backup API includes live
    /// WAL commits in each database copy; copying its main file and sidecars separately can corrupt a restore.
    /// Nothing in the staging tree changes while restic reads it, and no database lock is held through that run.
    func withStateSnapshot<T>(_ body: (URL) throws -> T) throws -> T {
        guard try StateDirectory.open(support, create: false) != nil else {
            throw Failure(message: "the support folder is missing")
        }
        // Use realpath's spelling: Foundation may remove /private while its enumerator keeps that prefix.
        guard let resolved = realpath(support.path, nil) else { throw Failure(message: "the support folder cannot be resolved") }
        defer { free(resolved) }
        let source = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let staging = dir.appendingPathComponent("run/state-\(UUID().uuidString)", isDirectory: true)
        try AtomicFile.makePrivateFolder(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let target = staging.appendingPathComponent("Support", isDirectory: true)
        try AtomicFile.makePrivateFolder(target)
        var failed = false
        guard let entries = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil,
                                                           errorHandler: { _, _ in failed = true; return false }) else {
            throw Failure(message: "the support folder cannot be read for backup")
        }
        let prefix = source.path + "/"
        for case let file as URL in entries {
            guard file.path.hasPrefix(prefix) else { throw Failure(message: "a state file is outside the support folder") }
            let relative = String(file.path.dropFirst(prefix.count))
            if Self.omittedStatePath(relative) { entries.skipDescendants(); continue }
            // Sidecars of state databases are represented by the standalone snapshot, never copied separately.
            if ["-wal", "-shm", "-journal"].contains(where: { relative.hasSuffix($0) && Self.stateDatabase(String(relative.dropLast($0.count))) }) {
                continue
            }
            let copy = target.appendingPathComponent(relative)
            if Self.stateDatabase(relative) {
                try StateStore.snapshot(file, to: copy)
                continue
            }
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw Failure(message: "a state file cannot be read for backup") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: try AtomicFile.makePrivateFolder(copy)
            case S_IFREG, S_IFLNK: try FileManager.default.copyItem(at: file, to: copy)
            default: throw Failure(message: "a special file in the support folder cannot be backed up safely")
            }
        }
        guard !failed else { throw Failure(message: "the support folder cannot be read for backup") }
        return try body(target)
    }

    private static func omittedStatePath(_ path: String) -> Bool {
        if ["backup/cache", "backup/run", "backup/verify", "backup/peek", "mcp/audit", "mcp/mcp.sock"].contains(path) { return true }
        let name = (path as NSString).lastPathComponent
        if name == ".teka.lock" || name == ".DS_Store" || (name.hasPrefix(".") && name.hasSuffix(".tmp")) { return true }
        for log in ["runtime/jobs.log", "runtime/lease-refusals.log"] {
            if path == log { return true }
            if path.hasPrefix(log + "."), let first = path.dropFirst(log.count + 1).utf8.first, (48...57).contains(first) { return true }
        }
        return false
    }
}
