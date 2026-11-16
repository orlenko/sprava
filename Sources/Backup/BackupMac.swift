import CryptoKit
import Darwin
import Foundation
import SpravaKit
import SystemConfiguration

/// Which Mac writes to a repository (docs/backup.md §3.1, decisions.md D44). Two Macs signed in to one Apple ID see
/// one iCloud Drive: were both to back up into one repository, one Mac's weekly forget and prune could remove the
/// other's snapshots. So each repository holds a small file naming the one Mac that writes to it, and that Mac's
/// snapshots carry a host of its own, which retention keeps to.
extension Backup {
    /// The file in a repository's folder that names the Mac writing to it. restic ignores files it does not know.
    static let markerName = "sprava-mac.json"

    /// The host restic recorded before D44, on every Mac alike: which Mac took such a snapshot cannot be told. The Mac
    /// that first marks a repository set up before D44 adopts them there, and its retention covers them from then on;
    /// a takeover hands them on with the rest (the marker's `legacy`). Elsewhere they are never forgotten.
    static let legacyHost = "sprava"

    /// Whether this Mac's retention in `repository` covers the snapshots taken before D44.
    static func adoptsLegacy(_ s: Settings, _ repository: URL) -> Bool {
        (s.legacy ?? []).contains(repository.standardizedFileURL.path)
    }

    static func adoptLegacy(_ s: inout Settings, _ repository: URL) {
        guard !adoptsLegacy(s, repository) else { return }
        s.legacy = (s.legacy ?? []) + [repository.standardizedFileURL.path]
    }

    /// This Mac in a repository and in its snapshots' host: a digest of its device id, which says nothing else.
    public static func macMark(_ deviceID: String) -> String {
        SHA256.hash(data: Data(("sprava-backup-mac:" + deviceID).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The host this Mac's snapshots carry.
    static func host(_ mark: String) -> String { "sprava-" + mark }

    /// What the marker holds: the Mac's mark, its name as the person knows it, for the message another Mac shows, and
    /// whether that Mac adopted the repository's snapshots from before D44, which a takeover then hands on.
    struct Marker: Codable, Equatable {
        var mac: String
        var name: String
        var legacy: Bool? = nil
    }

    /// The repository is another Mac's, or this Mac's backup settings were made on another Mac.
    public struct OtherMac: Error, CustomStringConvertible, Equatable, Codable, Sendable {
        /// "primary", "second", or "settings" (the settings came with Sprava's data from another Mac).
        public let repository: String
        /// The other Mac's name as its marker gives it; nil when there is none.
        public let name: String?

        public var description: String {
            if repository == "settings" {
                return "this Mac's backup settings were made on another Mac and came here with Sprava's data; nothing was "
                    + "backed up or pruned. Take the backups over to continue them from this Mac"
            }
            let which = repository == "second" ? "second backup" : "backup folder"
            let mac = name.map { "another Mac (\u{201C}\($0)\u{201D})" } ?? "another Mac"
            return "this \(which) belongs to \(mac), which backs up its own binders there; nothing was changed. Choose a "
                + "folder of this Mac's own, or take it over if that Mac no longer backs up to it"
        }
    }

    /// The Mac's name as System Settings shows it ("Sharing"), or a plain stand-in when it cannot be read.
    public static func thisMacName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?).map(cleanName) ?? "This Mac"
    }

    /// A name with control characters removed and its length bounded, so a marker cannot fill a page with one.
    static func cleanName(_ name: String) -> String {
        let kept = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return String(kept.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }

    /// A Mac's name as a folder name: no "/" or ":", no leading dot, never empty.
    public static func folderName(forMac name: String) -> String {
        var s = cleanName(name).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "This Mac" : s
    }

    /// The default mirror: a folder of this Mac's own in the person's iCloud Drive. It is chosen once, at setup, and
    /// kept in the settings: renaming the Mac later moves nothing.
    public static func defaultPrimary(macName: String = thisMacName()) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/Sprava Backup", isDirectory: true)
            .appendingPathComponent(folderName(forMac: macName), isDirectory: true)
    }

    /// The marker in `repository`; nil when there is none. A link, a folder or anything that is not a marker throws.
    static func readMarker(_ repository: URL) throws -> Marker? {
        let unreadable = Failure(message: "the backup folder's note of which Mac writes to it cannot be read; nothing was changed")
        let fd = open(repository.appendingPathComponent(markerName).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw unreadable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4096 else { throw unreadable }
        var buffer = [UInt8](repeating: 0, count: 4097)
        var count = 0
        while count < buffer.count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + count, $0.count - count) }
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw unreadable }
            if n == 0 { break }
            count += n
        }
        guard count <= 4096, let marker = try? JSONDecoder().decode(Marker.self, from: Data(buffer[0..<count])),
              marker.mac.wholeMatch(of: /[0-9a-f]{16}/) != nil else { throw unreadable }
        return Marker(mac: marker.mac, name: cleanName(marker.name), legacy: marker.legacy == true ? true : nil)
    }

    /// Marks `repository` as the Mac `mark`'s, saying whether that Mac adopted its snapshots from before D44.
    static func writeMarker(_ mark: String, into repository: URL, legacy: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try AtomicFile.write(try encoder.encode(Marker(mac: mark, name: thisMacName(), legacy: legacy ? true : nil)),
                                 to: repository.appendingPathComponent(markerName), mode: 0o644)
        } catch {
            throw Failure(message: "the backup folder could not be marked as this Mac's (\(error)); nothing was changed")
        }
    }

    /// Whether `repository` holds a restic repository: a folder that is away, or gone, holds none to mark.
    static func holdsRepository(_ repository: URL) -> Bool {
        var info = stat()
        return lstat(repository.appendingPathComponent("config").path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// A repository must not sit inside another: the default folder of a Mac set up before D44 is `Sprava Backup`
    /// itself, and another Mac's default, `Sprava Backup/<its name>`, would be inside it.
    static func refuseNestedRepository(_ repository: URL) throws {
        var folder = URL(fileURLWithPath: realPath(repository), isDirectory: true)
        while folder.path != "/" {
            folder.deleteLastPathComponent()
            var keys = stat()
            if holdsRepository(folder), lstat(folder.appendingPathComponent("keys").path, &keys) == 0, keys.st_mode & S_IFMT == S_IFDIR {
                throw Failure(message: "this folder is inside another backup (\(folder.lastPathComponent)); choose a folder beside it")
            }
        }
    }

    /// The configured repositories, each with the role an `OtherMac` names it by.
    func repositories(_ s: Settings) -> [(role: String, url: URL)] {
        [("primary", s.primary), ("second", s.second)].compactMap { role, path in
            path.map { (role, URL(fileURLWithPath: $0, isDirectory: true)) }
        }
    }

    /// Before a run: the settings were made on this Mac, and each configured repository names it. A repository with
    /// no marker yet (one set up before D44) is marked as this Mac's now, and this Mac adopts its snapshots from before
    /// D44; so is one the person took over while it was away (`pendingTakeOver`), once. One that is away is left for
    /// when it is back. Anything else throws `OtherMac` and changes nothing.
    public func confirmThisMac(_ deviceID: String) throws {
        let saved = try settings()
        var s = saved
        let mine = Self.macMark(deviceID)
        if let mac = s.mac, mac != mine { throw OtherMac(repository: "settings", name: nil) }
        var unmarked: [URL] = []
        for (role, url) in repositories(s) {
            let path = url.standardizedFileURL.path
            let pending = (s.pendingTakeOver ?? []).contains(path)
            switch try Self.readMarker(url) {
            case nil:
                guard Self.holdsRepository(url) else { break }
                Self.adoptLegacy(&s, url)
                unmarked.append(url)
            case let marker? where marker.mac == mine: break
            // A repository the person took over while it was away: that choice, once. A marker that names a Mac this
            // one took over earlier grants nothing by itself: the person may have handed the backups back since.
            case let marker? where pending:
                s.formerMacs = Array(Set((s.formerMacs ?? []) + [marker.mac])).sorted()
                if marker.legacy == true { Self.adoptLegacy(&s, url) }
                unmarked.append(url)
            case let marker?: throw OtherMac(repository: role, name: marker.name)
            }
            if pending, Self.holdsRepository(url) {
                s.pendingTakeOver = s.pendingTakeOver?.filter { $0 != path }
                if s.pendingTakeOver?.isEmpty == true { s.pendingTakeOver = nil }
            }
        }
        // The markers first: settings that adopt what no marker says would not hand it on at a takeover.
        for url in unmarked { try Self.writeMarker(mine, into: url, legacy: Self.adoptsLegacy(s, url)) }
        if s.mac == nil { s.mac = mine }
        if s != saved { try save(s) }
    }

    /// No command runs on a configured repository whose marker names another Mac than the settings do. A repository
    /// that is away has no marker to read; restic then fails on it as before. Reading another Mac's repository for a
    /// restore never comes here: only this Mac's own backups do.
    func requireMark(_ path: String, _ s: Settings) throws {
        guard let role = repositories(s).first(where: { $0.url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path })?.role
        else { return }
        // One with no marker (made before D44, or a new empty one put in its place) is marked by the next run
        // (`confirmThisMac`); retention never forgets another Mac's snapshots in it meanwhile (`applyRetention`).
        guard let marker = try Self.readMarker(URL(fileURLWithPath: path, isDirectory: true)) else { return }
        guard let mine = s.mac, marker.mac == mine else { throw OtherMac(repository: role, name: marker.name) }
    }

    /// Takes over the configured repositories after the person chose to (Settings › Backup): each that is here is
    /// marked as this Mac's, the Mac it named stops writing to it at its next run, and that Mac's snapshots join this
    /// Mac's in retention, with those from before D44 if that Mac had adopted them. The key must open each first. A
    /// second backup that is away is taken over at the first run
    /// after it is back (`pendingTakeOver`), whatever Mac its marker names then.
    public func takeOver(_ deviceID: String) throws {
        var s = try settings()
        let mine = Self.macMark(deviceID)
        var former = Set(s.formerMacs ?? [])
        if let mac = s.mac, mac != mine { former.insert(mac) }
        var marking: [URL] = []
        var pending: [String] = []
        for (role, url) in repositories(s) {
            guard role == "primary" || Self.holdsRepository(url) else {
                pending.append(url.standardizedFileURL.path)
                continue
            }
            _ = try engine(url.path, settings: s, marked: false).snapshots()
            if let marker = try Self.readMarker(url), marker.mac != mine {
                former.insert(marker.mac)
                if marker.legacy == true { Self.adoptLegacy(&s, url) }
            }
            marking.append(url)
        }
        for url in marking { try Self.writeMarker(mine, into: url, legacy: Self.adoptsLegacy(s, url)) }
        s.mac = mine
        s.formerMacs = former.isEmpty ? nil : former.sorted()
        s.pendingTakeOver = pending.isEmpty ? nil : pending
        try save(s)
        var st = try state()
        if st.otherMac != nil {
            st.otherMac = nil
            try save(st)
        }
    }
}
