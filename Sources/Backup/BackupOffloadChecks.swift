import BinderFormat
import BinderStore
import Darwin
import Foundation
import SpravaKit

/// What an offload checks before it starts, before it accepts its copies, and on the way: work waiting in the binder,
/// a binder that changed, a backup id another binder holds, the upload gates (docs/backup.md §6.1).
extension Backup {
    /// What stops a binder from leaving, checked when the offload starts and again before its copies are accepted
    /// (work may arrive meanwhile): its open items, for the person to confirm, or a failure.
    static func refuseNotReady(_ folder: URL, _ teka: Teka) throws -> [Item] {
        // Its hub slice is named by its catalog, so a binder whose name differs from its folder's (an outside edit may
        // have given it another binder's name) or cannot be read is put right first (`HubLane.withdrawBeforeLeaving`).
        guard !teka.federationBlocked else { throw Failure(message: Self.notOffloadable(teka) + "; put it right, then offload again") }
        // A card is done only when it is applied, rejected or superseded (binder-v0 §6.5): any other state, a torn or
        // edited one too, may be waiting.
        guard ProposalStore.list(in: folder).allSatisfy({ ["applied", "rejected", "superseded"].contains($0.0.state) }) else {
            throw Failure(message: "cards are waiting for this binder; approve or reject them first")
        }
        try refuseUnreadableCards(folder)
        // Nothing may wait in intake/ or outgoing/. In intake/, `_converted/` is regenerable text, and `mail/` is
        // looked into: its messages and their attachment folders wait like any file, while a mail monitor's `.env`
        // and `state.json` are never filed (binder-v0 §3.3). Each is left out only with its own type: a file named
        // `_converted`, or a folder named `.env`, waits like anything else. A hidden file waits like any other; only
        // what restic leaves out (`excludes`) does not. Only a folder that is not there is empty; one that cannot be
        // listed may hold anything.
        func waiting(_ sub: String, except: [String: mode_t]) throws -> Bool {
            let url = folder.appendingPathComponent(sub)
            var info = stat()
            if lstat(url.path, &info) != 0 {
                guard errno == ENOENT else { throw Failure(message: "\(sub)/ cannot be checked; nothing was removed") }
                return false
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw Failure(message: "\(sub)/ is not a real folder; nothing was removed")
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                throw Failure(message: "\(sub)/ cannot be listed; nothing was removed")
            }
            return names.contains { name in
                guard !Self.leftOut(name) else { return false }
                guard let type = except[name] else { return true }
                var entry = stat()
                return lstat(url.appendingPathComponent(name).path, &entry) != 0 || entry.st_mode & S_IFMT != type
            }
        }
        if try waiting("intake", except: ["mail": S_IFDIR, "_converted": S_IFDIR])
            || waiting("intake/mail", except: [".env": S_IFREG, "state.json": S_IFREG]) {
            throw Failure(message: "files are waiting in intake/; deal with them first")
        }
        if try waiting("outgoing", except: [:]) { throw Failure(message: "files are waiting in outgoing/; deal with them first") }
        return teka.items.filter { $0.declaredStatus != .done && !$0.isDismissed }
    }

    /// The open items the person has not confirmed for this offload: any whose id was not among those confirmed (or,
    /// for a job recorded before ids were kept, any beyond the number confirmed).
    static func unconfirmed(_ open: [Item], _ job: InProgress) -> [Item] {
        guard let confirmed = job.confirmedItems else { return open.count > job.openItemsConfirmed ? open : [] }
        return open.filter { !confirmed.contains(confirmationKey($0)) }
    }

    /// An item's id as confirmed, keeping its JSON type and exact characters: `7` and `"7"` are two ids, and so are
    /// two spellings of the same text.
    static func confirmationKey(_ item: Item) -> String {
        switch item.id {
        case .integer(let n)?: return "i:\(n)"
        case .string(let text)?: return "s:" + Data(text.utf8).base64EncodedString()
        case nil: return "x:" + Data(item.idText.utf8).base64EncodedString()
        }
    }

    /// Whether a second backup is in another cloud service's folder (`~/Library/CloudStorage`), whose upload must be
    /// seen before its copy counts as off this Mac; an external disk's copy counts once written.
    static func isCloudProviderLocation(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        realPath(url).hasPrefix(realPath(home.appendingPathComponent("Library/CloudStorage", isDirectory: true)) + "/")
    }

    /// A name restic never backs up (`excludes`): Finder's `.DS_Store`, the binder lock, a temporary file (`.*.tmp`,
    /// as `manifest` reads it).
    static func leftOut(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".teka.lock" || (name.utf8.count >= 5 && name.hasPrefix(".") && name.hasSuffix(".tmp"))
    }

    /// Every entry of the proposals folder must be a card `ProposalStore.list` read: a card that cannot be read (bad
    /// JSON, a name that is not its id, a link) may be one waiting, and would leave unseen. A proposals folder that is
    /// not a real folder, or cannot be listed, may hold anything.
    static func refuseUnreadableCards(_ folder: URL) throws {
        let cards = folder.appendingPathComponent(".sprava/proposals", isDirectory: true)
        let unreadable = Failure(message: "a card of this binder cannot be read (in .sprava/proposals); nothing was removed. Put it right, then offload again")
        var info = stat()
        if lstat(cards.path, &info) != 0 {
            guard errno == ENOENT else { throw unreadable }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, let names = try? FileManager.default.contentsOfDirectory(atPath: cards.path) else { throw unreadable }
        let read = Set(ProposalStore.list(in: folder).map { "\($0.0.id).json" })
        if names.contains(where: { !Self.leftOut($0) && !read.contains($0) }) { throw unreadable }
    }

    /// The iCloud upload gate (§3.4, §6.1 step 4): nil once macOS reports every file of the mirror uploaded, else how
    /// many still wait. A mirror macOS does not report as in iCloud at all (iCloud Drive off, or a folder outside it)
    /// is a copy on this Mac only, so nothing leaves the Mac on it.
    func uploadPending(_ repository: URL) throws -> Int? {
        switch uploadCheck(repository) {
        case .uploaded: return nil
        case .waiting(let n): return n
        case .notInICloud:
            throw Failure(message: "the backup mirror is not in iCloud (is iCloud Drive on?), so it is not yet a copy off this Mac; nothing was removed")
        }
    }

    /// Restores a snapshot into a private temporary folder and lists it as `manifest` does; the folder is removed after.
    func restoredManifest(_ snapshot: String, from r: Restic, id: String) throws -> [String: String] {
        let verify = dir.appendingPathComponent("verify/\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: verify)
        try AtomicFile.makePrivateFolder(verify)
        defer { try? FileManager.default.removeItem(at: verify) }
        try r.restore(snapshot, into: verify)
        return try Self.manifest(verify)
    }

    /// A copy of a binder carries its backup id. Offloading it would replace the other's offload record, the only
    /// way back to that binder, so an id another binder already uses is refused until the copy has its own. An
    /// offload left waiting at a folder that is gone (the binder moved meanwhile) starts over here instead.
    func refuseSharedID(_ id: String, folder: URL, _ st: inout State) throws {
        let refused = { (_: String) in
            Failure(message: "another binder has this binder's backup id; nothing was removed. "
                + "If this one is a copy, give it its own backup id; if that one is being restored, finish the restore first")
        }
        // The same folder reached another way (through a link, another case) is this binder, not a copy.
        if let job = st.offloads[id], !Self.sameFolder(URL(fileURLWithPath: job.path, isDirectory: true), folder) {
            guard job.stage != "leaving", Self.folderEntry(URL(fileURLWithPath: job.path, isDirectory: true)) == .missing else {
                throw refused(job.path)
            }
            // Its pins are released before it is forgotten; a repository that is away keeps it for the next try.
            try abandonOffload(id, job, &st)
        }
        let ownLeaving = st.offloads[id]?.stage == "leaving"
        if !ownLeaving, let record = st.offloaded.first(where: { $0.backupID == id }) { throw refused(record.originalPath) }
    }

    /// Stops an offload whose binder changed after its snapshot was verified: the job starts over next time.
    func refuseIfChanged(_ id: String, folder: URL, _ job: InProgress, _ st: inout State) throws {
        let manifest = try Self.manifest(folder), root = try Self.rootMetadata(folder)
        guard job.manifestSHA != Self.digest(manifest) || job.root != root else { return }
        try abandonOffload(id, job, &st)
        throw Failure(message: "the binder changed during the offload; nothing was removed. Offload again to back up the change")
    }

    /// Why a binder the hub does not trust with its name is not offloaded, in words the person can act on: the reasons
    /// it needs attention. For a stamped catalog without a valid `meta.disclosure` it says what that means on the hub:
    /// the hub withdraws the slice it recorded writing and publishes nothing from the binder until the level is set.
    static func notOffloadable(_ teka: Teka) -> String {
        let reasons = teka.states.filter { $0.key <= .needsAttention }.sorted { $0.key < $1.key }.flatMap(\.value)
        let disclosure = reasons.filter { $0.contains("meta.disclosure") }
        if !disclosure.isEmpty {
            let others = reasons.filter { !$0.contains("meta.disclosure") }
            return "this binder's catalog has no valid disclosure level (meta.disclosure), so the hub withdraws its slice and "
                + "publishes nothing from it; set its disclosure" + (others.isEmpty ? "" : ". It also needs attention: " + listed(others))
        }
        guard !reasons.isEmpty else { return "this binder's name cannot be used as a hub file name" }
        return "this binder needs attention: " + listed(reasons)
    }

    static func listed(_ reasons: [String]) -> String {
        reasons.prefix(3).joined(separator: "; ") + (reasons.count > 3 ? "; and \(reasons.count - 3) more" : "")
    }
}
