import Foundation
import SpravaKit

/// The owner record `.sprava/owner.json`: which Mac manages an adopted binder (architecture 2.3). Another Mac,
/// or a development build with its own device id, shows the binder read-only and never publishes or drains it.
public enum Owner {
    public static func device(of folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".sprava/owner.json")),
              let value = try? JSONParser.parse(data).value else { return nil }
        return value["device"]?.stringValue
    }
}
