import Foundation

/// Backup, offload and restore (docs/backup.md). One restic repository in iCloud Drive holds a snapshot per
/// binder and one of Sprava's own state; a second repository elsewhere holds the copies offloading requires.
///
/// A value for one operation: callers make a new one for each job or command, so it reads the backup key as it is
/// then, after a setup or a key replacement too.
public struct Backup: Sendable {
    public let support: URL
    /// The backup key, read once when the value is made (`BackupKey.load()`).
    public let key: String?
    public let resticBinary: URL?
    /// Whether iCloud has uploaded a repository (`uploadStatus(of:)`; tests pass their own).
    public let uploadCheck: @Sendable (URL) -> Upload
    /// Whether a second repository is on an independent destination: an external volume or a supported non-iCloud
    /// file-provider root. Tests substitute this because their repositories deliberately live on one temporary disk.
    let secondLocationCheck: @Sendable (URL) -> Bool
    /// Runs right after restic has read a binder; tests use it to land a write during a snapshot.
    var afterSnapshot: (@Sendable () -> Void)?
    /// Runs at each durable step boundary of a multi-step operation, named; tests take an image of the disk there,
    /// as a crash would leave it, and run the operation again from that image.
    var atStep: (@Sendable (String) -> Void)?

    func step(_ name: String) { atStep?(name) }

    public init(support: URL, key: String? = BackupKey.load(), resticBinary: URL? = Restic.locate(),
                uploadCheck: @escaping @Sendable (URL) -> Upload = { Backup.uploadStatus(of: $0) }) {
        self.init(support: support, key: key, resticBinary: resticBinary, uploadCheck: uploadCheck,
                  secondLocationCheck: { Backup.isIndependentSecondLocation($0) })
    }

    /// Test seam for repositories that deliberately share a temporary volume. Production callers always use the
    /// public initializer and the real independent-destination check.
    init(support: URL, key: String?, resticBinary: URL? = Restic.locate(), uploadCheck: @escaping @Sendable (URL) -> Upload,
         secondLocationCheck: @escaping @Sendable (URL) -> Bool) {
        self.support = support
        self.key = key
        self.resticBinary = resticBinary
        self.uploadCheck = uploadCheck
        self.secondLocationCheck = secondLocationCheck
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }
}
