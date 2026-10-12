import Foundation
import Shelf

extension ShelfStore {
    /// The Shelf as a job reads it: a shelf.json, or a registry the Shelf shows, that exists but cannot be read
    /// throws, so a job fails instead of reporting an empty Shelf as all done (the app's display path keeps `rows`).
    public func rowsForJobs() throws -> [ShelfRow] {
        let picked = try readFolders()
        return Shelf.rows(registry: try registryForShelf(), picked: picked)
    }
}
