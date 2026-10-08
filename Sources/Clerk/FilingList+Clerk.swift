import BinderStore
import Foundation
import Shelf

extension FilingList {
    /// The binders the clerk may file into, with their index words. Only adopted binders this Mac manages, on the
    /// list, with a description; names must be unique and never `not-sure`. A binder at disclosure `none` goes by an
    /// opaque label, so the model never sees its name; code maps the label back by `folder` (architecture 5.4).
    public func binders(rows: [ShelfRow], deviceID: String) -> [FilingBinder] {
        let all = load()
        var seen = Set<String>()
        return rows.compactMap { row in
            guard row.teka.isAdopted, !row.teka.writesBlocked, Owner.device(of: row.folder) == deviceID,
                  let entry = all[row.folder.standardizedFileURL.path], entry.filing, !entry.description.isEmpty else { return nil }
            let name = Self.name(of: row)
            guard name != "not-sure", seen.insert(name).inserted else { return nil }
            return FilingBinder(name: name, description: entry.description, folder: row.folder,
                                words: FilingBinder.index(catalog: row.teka.catalog, description: entry.description),
                                openItems: FilingBinder.candidates(catalog: row.teka.catalog))
        }
    }
}
