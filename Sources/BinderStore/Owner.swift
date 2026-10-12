import Foundation
import SpravaKit

/// The owner record `.sprava/owner.json`: which Mac manages an adopted binder (architecture 2.3). Another Mac,
/// or a development build with its own device id, shows the binder read-only and never publishes or drains it.
public enum Owner {
    /// An owner record is a few lines; anything larger is damaged.
    public static let recordLimit = 64 * 1024

    /// nil when there is no record or it cannot be used: a link is not followed, a FIFO is not waited on, and a
    /// file over `recordLimit` is not read (SafeFile).
    public static func device(of folder: URL) -> String? {
        guard case .ok(let data) = SafeFile.read(folder.appendingPathComponent(".sprava/owner.json"), limit: recordLimit),
              let value = try? JSONParser.parse(data).value else { return nil }
        return value["device"]?.stringValue
    }
}
