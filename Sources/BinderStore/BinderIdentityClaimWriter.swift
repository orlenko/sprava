import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// The exclusive claim-write phase of binder-v0 §7.2.2. Internal plumbing, with no runtime caller.
/// The management owner must have proved folder ownership before it created the pending allocation.
/// A pending intent and a written claim are NOT admission. The future owner must lock and reconcile
/// the current folder, claim and trusted binding again before issuing any capability.
struct BinderIdentityClaimWriter: Sendable {
    enum Refused: Error { case noPendingIntent, instanceMismatch, unsafeFolder, unsafeStateDirectory, claimNotReadable }
    let allocations: BinderIdentityAllocations

    /// A wrong or missing intent causes no writes. In particular, a copied claim is never reminted or replaced.
    /// `publish` is an internal fixture boundary for a lost reply after publication, not an authority provider.
    func writePending(requestID: UUID, in folder: URL, lockTimeout: TimeInterval = 10,
                      publish: (StateDirectory, Data) throws -> Void = { try $0.createImmutable($1, to: "binder-identity.json") }
    ) throws -> BinderIdentityClaim {
        guard let intent = try allocations.pending(requestID: requestID) else { throw Refused.noPendingIntent }
        guard try BinderIdentityAllocations.FolderInstance.capture(folder) == intent.instance else {
            throw Refused.instanceMismatch
        }
        return try TekaStore(folder: folder).withLock(timeout: lockTimeout) {
            guard try allocations.pending(requestID: requestID) == intent,
                  try BinderIdentityAllocations.FolderInstance.capture(folder) == intent.instance else {
                throw Refused.instanceMismatch
            }
            guard let root = try StateDirectory.open(folder), let state = try root.directory(".sprava", create: true) else {
                throw Refused.unsafeFolder
            }
            // Existing broader modes are refused, never silently accepted as private claim storage.
            var info = stat()
            guard lstat(folder.appendingPathComponent(".sprava").path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
                throw Refused.unsafeStateDirectory
            }
            let id = intent.binderID.uuidString.lowercased()
            let bytes = Data("{\"format_version\":\"0\",\"binder_id\":\"\(id)\"}\n".utf8)
            try publish(state, bytes)
            guard case .claim(let claim) = BinderIdentityClaim.read(in: folder), claim.binderID == id else {
                throw Refused.claimNotReadable
            }
            return claim
        }
    }
}

extension BinderIdentityAllocations.FolderInstance {
    /// Inspect an explicitly supplied candidate only; no path/name/device ownership hint becomes authority.
    /// The management owner records this instance under its writer lock after proving ownership separately.
    static func capture(_ folder: URL) throws -> Self {
        guard folder.isFileURL else { throw BinderIdentityClaimWriter.Refused.unsafeFolder }
        let descriptor = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw BinderIdentityClaimWriter.Refused.unsafeFolder }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw BinderIdentityClaimWriter.Refused.unsafeFolder }
        return Self(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino),
                    birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }
}
