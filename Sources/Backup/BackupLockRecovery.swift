import Darwin
import Foundation
import SpravaKit

extension Backup {
    /// An encrypted restic lock records the system hostname and the process that holds it. Snapshot host tags
    /// are separate. A slow or sleeping process can hold a lock for hours, so age alone cannot authorize removal.
    private struct LockOwner: Decodable {
        let hostname: String
        let pid: Int32
        let uid: UInt32
    }

    /// Called under the backup job's state lock, after this Mac has confirmed ownership of the repositories.
    /// Only remove an individual lock after the pinned restic has authenticated it and its local owner is gone.
    func recoverAbandonedLocks(in repository: URL, mark: String) throws {
        let folder = repository.appendingPathComponent("locks", isDirectory: true)
        guard SafeFile.isTrustedFolder(folder),
              let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [],
                                                          options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return }
        var hostname = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&hostname, hostname.count) == 0,
              let localHost = hostname.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) }),
              !localHost.isEmpty else { return }
        var reader: Restic?
        // Diagnostics on a damaged mirror must not launch an unlimited sequence of restic processes.
        let deadline = ContinuousClock.now + .seconds(15)
        for case let file as URL in entries {
            guard ContinuousClock.now < deadline else { return }
            let id = file.lastPathComponent
            guard id.wholeMatch(of: /[0-9a-f]{64}/) != nil else { continue }
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_size > 0, info.st_size <= 4096 else { continue }
            guard try Self.readMarker(repository)?.mac == mark else { return }
            if info.st_flags & UInt32(SF_DATALESS) != 0 {
                try FileManager.default.startDownloadingUbiquitousItem(at: file)
                // The job can retry once iCloud has delivered the bytes. A placeholder alone proves no ownership.
                continue
            }
            if reader == nil { reader = try engine(repository.path) }
            guard let reader else { return }
            let result = try reader.run(["cat", "lock", id, "--no-lock"], timeout: 15)
            guard result.status == 0, let owner = try? JSONDecoder().decode(LockOwner.self, from: result.stdout),
                  owner.hostname == localHost, owner.uid == getuid(), owner.pid > 0,
                  kill(owner.pid, 0) == -1, errno == ESRCH else { continue }
            // restic refreshes a lock by creating a NEW content-addressed file. This exact name can never
            // become a refreshed lock. It may already have disappeared while we checked.
            guard unlink(file.path) == 0 || errno == ENOENT else {
                throw Failure(message: "the abandoned backup lock could not be removed")
            }
        }
    }
}
