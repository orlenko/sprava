import CryptoKit
import Darwin
import Foundation
import IOKit
import SpravaKit

/// This Mac's device id, which every adopted binder's owner record names (architecture 2.3). The architecture keeps
/// it in the Keychain as a this-device-only item, never in a file that Migration Assistant or a restore copies, so
/// two Macs can never both claim a binder. That needs a signed build (spike g; review R9). Until then it is a file
/// in Sprava's own state bound to this Mac: beside the id it records a digest of the Mac's hardware id, and a file
/// that names another Mac is a copy, set aside and replaced by a new id, so the copied binders need the takeover
/// card instead of being written from two Macs.
public enum DeviceID {
    public struct Unreadable: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "\(path) exists but is not a device id; it was left as it is" }
    }

    /// The id. It is made only when the file is absent (or names another Mac), under the directory's lock so two
    /// processes starting at once agree, and always read back from disk. A file that exists but cannot be read
    /// throws: a new id would make every binder this Mac owns read-only here.
    public static func load(support: URL, machine: String? = nil, now: Date = Date()) throws -> String {
        let machine = try machine ?? thisMac()
        let url = support.appendingPathComponent("device-id")
        guard let folder = try StateDirectory.open(support, create: true) else { throw Unreadable(path: url.path) }
        if let stored = try read(folder, path: url.path), stored.machine == machine { return stored.id }
        // Making, binding or replacing the id happens under a lock, so two first starts never set aside each
        // other's new id.
        try withLock(folder) { try settle(folder, path: url.path, machine: machine, now: now) }
        guard let stored = try read(folder, path: url.path), stored.machine == machine else { throw Unreadable(path: url.path) }
        return stored.id
    }

    /// The id, read only: nil when there is none yet or the file names another Mac (a copy, so no binder is this
    /// Mac's yet). Never makes, binds or sets aside an id; for readers such as the app's Health page.
    public static func existing(support: URL, machine: String? = nil) throws -> String? {
        guard let stored = try read(support.appendingPathComponent("device-id")) else { return nil }
        if let bound = stored.machine, try bound != (machine ?? thisMac()) { return nil }
        return stored.id
    }

    static func settle(_ folder: StateDirectory, path: String, machine: String, now: Date) throws {
        if let stored = try read(folder, path: path) {
            switch stored.machine {
            case machine: return
            case nil:
                // Written before ids were bound to a Mac, here: the same id, now bound.
                try create(folder: folder, id: stored.id, machine: machine)
            default:
                // A copy from another Mac: kept aside, never used, and never deleted.
                let stamp = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!).replacingOccurrences(of: ":", with: "")
                let aside = "device-id.from-another-mac-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
                // Exclusive, so an earlier copy set aside under the same name is never replaced.
                try folder.rename("device-id", to: aside)
                try create(folder: folder, id: UUID().uuidString.lowercased(), machine: machine)
            }
        } else {
            try create(folder: folder, id: UUID().uuidString.lowercased(), machine: machine)
        }
    }

    static func withLock(_ folder: StateDirectory, _ body: () throws -> Void) throws {
        let fd = try folder.openLock("device-id.lock")
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw AtomicFile.Failure(step: "lock device-id", code: errno) }
        }
        defer { flock(fd, LOCK_UN) }
        try body()
    }

    /// Writes through the retained directory while its lock is held. The file and its directory entry reach disk
    /// before the id is used: a power loss must not lose it and make a new one.
    static func create(folder: StateDirectory, id: String, machine: String) throws {
        let text = Data((id + "\n" + machine + "\n").utf8)
        try folder.write(text, to: "device-id")
    }

    /// nil when the file is absent; throws when it exists and does not hold a lowercase UUID (and, on a second
    /// line, a machine digest), or is a link, a folder or another user's file.
    static func read(_ url: URL) throws -> (id: String, machine: String?)? {
        guard let folder = try StateDirectory.open(url.deletingLastPathComponent()) else { return nil }
        return try read(folder, path: url.path)
    }

    static func read(_ folder: StateDirectory, path: String) throws -> (id: String, machine: String?)? {
        let data: Data
        switch try folder.read("device-id", limit: 1024) {
        case .ok(let read): data = read
        case .missing: return nil
        case .refused, .unreadable: throw Unreadable(path: path)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Unreadable(path: path) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(lines.count),
              lines[0].wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil,
              lines.count == 1 || lines[1].wholeMatch(of: /[0-9a-f]{64}/) != nil else { throw Unreadable(path: path) }
        return (lines[0], lines.count == 2 ? lines[1] : nil)
    }

    /// A digest of this Mac's hardware id (`IOPlatformUUID`), so the file names the Mac without holding the id.
    public static func thisMac() throws -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { throw AtomicFile.Failure(step: "read this Mac's hardware id", code: ENODEV) }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !uuid.isEmpty else {
            throw AtomicFile.Failure(step: "read this Mac's hardware id", code: ENODEV)
        }
        return SHA256.hash(data: Data(("sprava-device-id:" + uuid).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
