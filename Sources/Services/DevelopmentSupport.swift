import BinderStore
import Foundation
import Shelf
import SpravaKit

/// Where development runs keep their state: the installed app's support folder with `-dev` added, which
/// `sprava-runtime --dev` and the `sprava dev` commands share. Its own device id, records and client registry, so
/// a development run never shares a read-modify-write with the installed runtime, and binders the installed app
/// owns are read-only to it.
public enum DevelopmentSupport {
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let production = SpravaPaths.supportDirectory(environment: environment)
        return production.deletingLastPathComponent().appendingPathComponent(production.lastPathComponent + "-dev", isDirectory: true)
    }
}

/// The development CLI's safety checks. Its commands run with an identity and state of their own, never the
/// installed app's, and never touch a live binder: one lifeproj's registry lists, one on the installed app's Shelf
/// (a binder Sprava created need not be in the registry), or one the installed app owns. A registry or Shelf that
/// exists but cannot be read refuses everything, since it might list the folder; only an absent one allows. Their
/// state is `DevelopmentSupport.directory()`, shared with `sprava-runtime --dev`.
public enum DevelopmentGuard {
    /// Why development commands refuse `folder`, or nil when they may run. `productionSupport` is the installed
    /// app's support folder.
    public static func refusal(for folder: URL, registryURL: URL = LifeprojRegistry.defaultPath(),
                               productionSupport: URL = SpravaPaths.supportDirectory()) -> String? {
        // Compared after resolving links, so a link to a live binder is refused too.
        func real(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        }
        let target = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if FileManager.default.fileExists(atPath: registryURL.path) {
            let registry: LifeprojRegistry
            do { registry = try LifeprojRegistry.load(from: registryURL) } catch {
                return "lifeproj's registry exists but cannot be read; development commands refuse to run"
            }
            if registry.entries.contains(where: { $0.workingDir.map(real) == target }) {
                return "\(folder.path) is in lifeproj's registry; development commands work on invented copies only"
            }
        }
        let shelf: [URL]
        do { shelf = try ShelfStore(supportDirectory: productionSupport).readFolders() } catch {
            return "Sprava's Shelf exists but cannot be read; development commands refuse to run"
        }
        if shelf.contains(where: { real($0.path) == target }) {
            return "\(folder.path) is on Sprava's Shelf; development commands work on invented copies only"
        }
        // A binder the installed app owns. Its id is only read here, never made.
        // Read as the command table does: no link followed, no FIFO waited on, a bounded regular file. A record that
        // is there but cannot be read leaves the owner unknown, so development commands refuse.
        let ownerRecord = folder.appendingPathComponent(".sprava/owner.json")
        var info = stat()
        let recordExists = lstat(ownerRecord.path, &info) == 0
        let owner = Commands.ownerDevice(of: folder)
        if recordExists, owner == nil {
            return "the owner record of \(folder.path) cannot be read; development commands refuse to run"
        }
        if let owner {
            let installed: String?
            do { installed = try DeviceID.existing(support: productionSupport) } catch {
                return "Sprava's device id cannot be read, so the owner of \(folder.path) is unknown; development commands refuse to run"
            }
            if owner == installed {
                return "\(folder.path) is managed by the installed Sprava; development commands work on invented copies only"
            }
        }
        return nil
    }
}
