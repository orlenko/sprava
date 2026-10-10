import Darwin
import DiskArbitration
import Dispatch
import FileProvider
import Foundation

extension Backup {
    /// A path with symbolic links resolved, also for a folder not created yet (through its nearest existing parent).
    static func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    /// A supported independent destination: a non-iCloud File Provider root or a non-internal volume that is a real
    /// disk. A mounted disk image is refused: its backing file may sit in the mirror's iCloud folder, or on the
    /// internal disk, and go with it.
    static func isIndependentSecondLocation(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileProviderCheck: (URL) -> Bool = { registeredFileProvider(at: $0) },
        diskImageCheck: (URL) -> Bool? = { isDiskImage($0) }
    ) -> Bool {
        let destination = realPath(url)
        let providers = realPath(home.appendingPathComponent("Library/CloudStorage", isDirectory: true))
        if destination.hasPrefix(providers + "/") {
            // A directory entry alone is not proof: ask macOS to identify the owning provider domain.
            let relative = destination.dropFirst(providers.count + 1)
            guard let providerName = relative.split(separator: "/").first else { return false }
            var provider = stat()
            let root = URL(fileURLWithPath: providers, isDirectory: true)
                .appendingPathComponent(String(providerName), isDirectory: true)
            return lstat(root.path, &provider) == 0 && provider.st_mode & S_IFMT == S_IFDIR && fileProviderCheck(root)
        }

        var existing = URL(fileURLWithPath: destination, isDirectory: true)
        var info = stat()
        while lstat(existing.path, &info) != 0, existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        guard lstat(existing.path, &info) == 0,
              let values = try? existing.resourceValues(forKeys: [.volumeIsInternalKey]),
              let internalVolume = values.volumeIsInternal, !internalVolume else { return false }
        // A volume that cannot be identified is not trusted to be independent either.
        return diskImageCheck(existing) == false
    }

    /// Whether the volume holding `url` is a mounted disk image, as DiskArbitration describes its device; nil when
    /// it cannot say.
    static func isDiskImage(_ url: URL) -> Bool? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
        guard deviceProtocol != nil || model != nil else { return nil }
        return deviceProtocol == "Virtual Interface" || model?.trimmingCharacters(in: .whitespaces) == "Disk Image"
    }

    private final class FileProviderResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Resolves a user-visible provider URL through macOS itself. A bounded wait turns a wedged extension into refusal.
    static func registeredFileProvider(at root: URL, timeout: TimeInterval = 3) -> Bool {
        let answer = FileProviderResult()
        let finished = DispatchSemaphore(value: 0)
        NSFileProviderManager.getIdentifierForUserVisibleFile(at: root) { item, domain, error in
            answer.set(item != nil && domain != nil && error == nil)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else { return false }
        return answer.get()
    }

    func refuseSharedFate(_ second: URL, primary: URL) throws {
        let a = Self.realPath(second), b = Self.realPath(primary)
        if a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") {
            throw Failure(message: "the second backup must be a folder of its own, not the iCloud mirror or a folder in or around it")
        }
        let iCloud = Self.realPath(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Mobile Documents", isDirectory: true))
        if a == iCloud || a.hasPrefix(iCloud + "/") {
            throw Failure(message: "the second backup cannot be in iCloud Drive: losing the account would lose both copies; choose an external disk or another cloud service's folder")
        }
        guard secondLocationCheck(second) else {
            throw Failure(message: "the second backup must be on an external disk or in another cloud service's folder; a folder on this Mac is not an independent copy")
        }
    }

    /// The same check on saved settings, before an offload counts the repositories as independent copies.
    func refuseSharedFate(_ settings: Settings) throws {
        guard let primary = settings.primary, let second = settings.second else { return }
        try refuseSharedFate(URL(fileURLWithPath: second, isDirectory: true),
                             primary: URL(fileURLWithPath: primary, isDirectory: true))
    }
}
