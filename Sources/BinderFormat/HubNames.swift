import Foundation
import SpravaKit

/// The federation profile (binder-v0 §8). This part is what a binder's own rules need from the hub lane: the spool
/// name test and the slice ids. Publishing and draining extend it in the Hub target.
public enum HubLane {
    /// A binder name usable as one file name in the spool: no separators, not a dot name, no control characters.
    public static func isSafeSegment(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 200 && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// lifeproj's `str()` of an id: strings as is, integers in decimal.
    package static func idText(_ id: JSONValue) -> String {
        if case .string(let s) = id { return s }
        if case .number(let n) = id { return n.text }
        return canonicalText(id)
    }

    /// The slice id of an item that is not redacted.
    public static func plainSliceID(_ id: JSONValue, teka: String) -> String {
        let text = idText(id)
        return text.hasPrefix("\(teka)-") ? text : "\(teka)-\(text)"
    }
}
