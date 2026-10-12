import BinderFormat
import Foundation
import Shelf
import SpravaKit

/// What the app's Shelf shows, read in the app's own process so it works while the runtime is stopped
/// (architecture 2.1). Reads only: adding or removing a folder is a command the runtime carries out
/// (`shelf_add`, `shelf_remove`), since `shelf.json` is the runtime's to write (architecture 2.3).
public enum ShelfSnapshot {
    public struct Snapshot: Sendable {
        /// The binders, the one opened last on top (`RecentBinders.order`).
        public var rows: [ShelfRow] = []
        /// What could not be read, in a sentence; the rows show what could.
        public var note: String?
    }

    public static func read(support: URL) -> Snapshot {
        let store = ShelfStore(supportDirectory: support)
        var out = Snapshot()
        var notes: [String] = []
        // lifeproj's registry is on the Shelf only when the person turned it on (shelf.json "showRegistry").
        var registry: LifeprojRegistry?
        do { registry = try store.registryForShelf() } catch {
            notes.append("lifeproj's registry could not be read: \(error.localizedDescription)")
        }
        var picked: [URL] = []
        do { picked = try store.readFolders() } catch { notes.append("\(error)") }
        out.rows = RecentBinders.order(Shelf.rows(registry: registry, picked: picked),
                                       opened: RecentBinders(supportDirectory: support).opened())
        out.note = notes.isEmpty ? nil : notes.joined(separator: "\n")
        return out
    }
}
