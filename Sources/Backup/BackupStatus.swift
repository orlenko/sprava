import Foundation

extension Backup {
    public enum Upload: Equatable, Sendable {
        case notInICloud
        case uploaded
        case waiting(Int)
    }

    struct UploadEntry {
        var regular: Bool?
        var ubiquitous: Bool?
        var uploaded: Bool?
    }

    static func uploadStatus(_ entries: [UploadEntry?]) -> Upload {
        var pending = 0
        var ubiquitous = false
        for entry in entries {
            guard let entry else { pending += 1; continue }
            if entry.regular == false { continue }
            guard entry.regular == true else { pending += 1; continue }
            guard entry.ubiquitous == true else { pending += 1; continue }
            ubiquitous = true
            if entry.uploaded != true { pending += 1 }
        }
        if !ubiquitous { return .notInICloud }
        return pending == 0 ? .uploaded : .waiting(pending)
    }

    /// Whether macOS reports every file of a repository as uploaded to iCloud (docs/backup.md §3.4).
    public static func uploadStatus(of repository: URL) -> Upload {
        let (entries, complete) = uploadEntries(of: repository)
        return uploadStatus(complete ? entries : entries + [nil])
    }

    /// The repository entries and whether Foundation traversed every subtree.
    static func uploadEntries(of repository: URL) -> ([UploadEntry?], Bool) {
        let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .isRegularFileKey]
        var complete = true
        guard let walker = FileManager.default.enumerator(at: repository, includingPropertiesForKeys: keys,
            errorHandler: { _, _ in complete = false; return true }) else { return ([], false) }
        var entries: [UploadEntry?] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { entries.append(nil); continue }
            entries.append(UploadEntry(regular: values.isRegularFile, ubiquitous: values.isUbiquitousItem,
                                       uploaded: values.ubiquitousItemIsUploaded))
        }
        return (entries, complete)
    }

    public struct Status: Sendable {
        public var configured: Bool
        public var secondConfigured: Bool
        public var binders: [(id: String, at: String?, error: String?)]
        public var upload: Upload?
        public var lastCheck: String?
        public var lastDrill: String?
        public var offloaded: Int
        public var pending: Int
        /// Set when the backup's state cannot be read; nothing else is shown from it then.
        public var stateError: String?
        /// Set when backup settings cannot be read; backup then counts as neither set up nor ready for setup.
        public var settingsError: String?
        /// Documents deleted for good: when the backups stopped holding each, or why they still do.
        public var forgetting: [Forgetting] = []
        /// The second backup's last structure check (nil: none yet, or no second backup).
        public var lastSecondCheck: String? = nil
    }

    public func status(checkUpload: Bool = true) -> Status {
        var settings = Settings()
        var settingsError: String?
        do { settings = try self.settings() } catch { settingsError = "\(error)" }
        var state = State()
        var stateError: String?
        do { state = try self.state() } catch { stateError = "\(error)" }
        return Status(configured: settings.primary != nil && key != nil, secondConfigured: settings.second != nil,
                      binders: state.binders.sorted { $0.key < $1.key }.map { ($0.key, $0.value.at, $0.value.error) },
                      upload: checkUpload ? settings.primary.map { uploadCheck(URL(fileURLWithPath: $0)) } : nil,
                      lastCheck: state.lastCheck, lastDrill: state.lastDrill, offloaded: state.offloaded.count,
                      pending: state.offloads.count, stateError: stateError, settingsError: settingsError,
                      forgetting: state.forgetting, lastSecondCheck: state.lastSecondCheck)
    }
}
