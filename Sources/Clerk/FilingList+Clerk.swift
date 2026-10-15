import BinderFormat
import BinderStore
import Foundation
import Shelf

extension FilingList {
    /// The binders the clerk may file into, with their index words. Only adopted binders this Mac manages, on the
    /// list (by default, unless the person took them off), names unique and never `not-sure`. A binder at disclosure
    /// `none` is on it only when the person put it there with a description, and goes by an opaque label, so the model
    /// never sees its name; code maps the label back by `folder` (architecture 5.4).
    ///
    /// `hint` is the binder the person named with the note being read (capture-event-v0 §6.4 step 2, §8.1): an
    /// adopted binder this Mac manages, not at disclosure `none`, and the only one of that name, is offered for this
    /// note even when it is off the list, so a note typed on a binder's page stays there.
    public func binders(rows: [ShelfRow], deviceID: String, hint: String? = nil) -> [FilingBinder] {
        let all = load()
        var seen = Set<String>()
        var list: [FilingBinder] = rows.compactMap { row in
            guard Self.mayFile(row, deviceID: deviceID) else { return nil }
            let entry = all[row.folder.standardizedFileURL.path] ?? Self.defaultEntry(folder: row.folder, teka: row.teka)
            guard entry.filing else { return nil }
            // A binder at disclosure none needs the neutral line the person wrote: its label alone means nothing.
            if entry.description.isEmpty, PrivacyRatchet.disclosure(row) == "none" { return nil }
            // A binder whose label cannot be made (the label key is unreadable) is left out, never named.
            guard let name = try? self.name(of: row), name != "not-sure", seen.insert(name).inserted else { return nil }
            return Self.binder(row, name: name, description: entry.description)
        }
        if let hint, hint != "not-sure", !seen.contains(hint) {
            let named = rows.filter { $0.name == hint && Self.mayFile($0, deviceID: deviceID) && PrivacyRatchet.disclosure($0) != "none" }
            if named.count == 1, let row = named.first {
                list.append(Self.binder(row, name: hint, description: all[row.folder.standardizedFileURL.path]?.description ?? ""))
            }
        }
        return list
    }

    /// A binder's entry until the person saves one: on the list, with the summary line of its README.md, unless it is
    /// at disclosure `none`, which stays off until the person opts it in with a line they wrote (architecture 5.4).
    public static func defaultEntry(folder: URL, teka: Teka) -> Entry {
        Entry(description: readmeLine(folder) ?? "", filing: PrivacyRatchet.disclosure(folder: folder, teka: teka) != "none")
    }

    static func mayFile(_ row: ShelfRow, deviceID: String) -> Bool {
        row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == deviceID
    }

    static func binder(_ row: ShelfRow, name: String, description: String) -> FilingBinder {
        FilingBinder(name: name, description: description, folder: row.folder,
                     words: FilingBinder.index(catalog: row.teka.catalog, description: description),
                     openItems: FilingBinder.candidates(catalog: row.teka.catalog))
    }
}
