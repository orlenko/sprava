import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// A file the person dropped on a binder, copied into its `intake/` (conversation.md 5.1). The app opened the file;
/// this copies from that open file, never from a path, and never replaces anything already in `intake/`. The intake
/// watcher then cards it like any other arrival.
public enum IntakeDrop {
    public enum Refused: Error, Equatable { case notAFile, tooLarge, keyFile, changed, noSpace, unavailable }
    /// One file's bound. A drop's own bounds (count, total) are the app's, before anything is sent.
    public static let fileLimit = 512 * 1024 * 1024
    /// Free space the binder's volume keeps after the copy (conversation.md 5, proposed).
    public static let reserve: Int64 = 5 * 1024 * 1024 * 1024

    /// Copies the open file `fd` into `folder/intake/` as `name` made safe, or `name 2`, `name 3`… when that is taken.
    /// Returns the intake path written. The same bytes dropped again under the same name land on the first copy.
    public static func publish(_ fd: Int32, name: String, into folder: URL,
                               freeSpace: (URL) -> Int64? = Self.freeSpace) throws -> String {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Refused.notAFile }
        guard info.st_size <= fileLimit else { throw Refused.tooLarge }
        let base = DocumentPaths.safeName((name as NSString).lastPathComponent)
        // A key or credential file stays where it is, whatever it is called on the way here (binder-v0 §3.3): the
        // offered name, the cleaned one, and the name of the file the descriptor really is.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &path) == 0 else { throw Refused.notAFile }
        let real = (String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) as NSString).lastPathComponent
        guard ![name, base, real].contains(where: DocumentPaths.isKeyFile) else { throw Refused.keyFile }
        if let free = freeSpace(folder), free < Int64(info.st_size) + reserve { throw Refused.noSpace }
        guard case .ok(let data) = SafeFile.read(fd: fd, limit: fileLimit) else { throw Refused.notAFile }
        guard data.count == Int(info.st_size) else { throw Refused.changed }
        guard let binder = try StateDirectory.open(folder), let intake = try binder.directory("intake", create: true) else {
            throw Refused.unavailable
        }
        let stem = (base as NSString).deletingPathExtension, ext = (base as NSString).pathExtension
        for n in 1...100 {
            let candidate = n == 1 ? base : ext.isEmpty || stem.isEmpty ? "\(base) \(n)" : "\(stem) \(n).\(ext)"
            // `mail` and `_converted` are the intake's own folders; a file by that name would never be carded.
            guard DocumentPaths.isIntake("intake/" + candidate), !["mail", "_converted"].contains(candidate.lowercased()) else { continue }
            do {
                try intake.createImmutable(data, to: candidate)
                return "intake/" + candidate
            } catch let failure as AtomicFile.Failure where failure.code == EEXIST {
                continue
            }
        }
        throw Refused.unavailable
    }

    public static func freeSpace(_ folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}
