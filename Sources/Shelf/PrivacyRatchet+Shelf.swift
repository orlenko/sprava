import BinderStore
import Foundation

extension PrivacyRatchet {
    /// The disclosure every cross-binder surface uses for a Shelf row.
    public static func disclosure(_ row: ShelfRow) -> String {
        disclosure(folder: row.folder, teka: row.teka)
    }
}
