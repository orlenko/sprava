import Foundation
import SpravaKit

/// A validated, untrusted identity claim (binder-v0 §7.2.2), never an admitted binding or capability.
/// Reading does not allocate an id, open a trusted store, or enable identity-dependent work.
public struct BinderIdentityClaim: Sendable, Equatable {
    public let binderID: String

    private init(binderID: String) { self.binderID = binderID }

    /// Failures carry no file contents or caller-controlled error text. Only `absent` means no record.
    public enum ReadResult: Sendable, Equatable {
        case absent, unreadable, refused, malformed, unsupportedVersion
        case claim(BinderIdentityClaim)
    }

    private static let byteLimit = 16 * 1024

    /// Opens `.sprava` through the retained binder handle; no link or special file inside it is followed.
    /// The caller chooses the candidate folder. This does not prove ownership or admit that folder.
    public static func read(in folder: URL) -> ReadResult {
        do {
            guard let binder = try StateDirectory.open(folder) else { return .unreadable }
            guard let state = try binder.directory(".sprava") else { return .absent }
            switch try state.read("binder-identity.json", limit: byteLimit) {
            case .missing: return .absent
            case .refused: return .refused
            case .unreadable: return .unreadable
            case .ok(let data): return decode(data)
            }
        } catch { return .unreadable }
    }

    /// Strict bounded JSON, including unknown fields; duplicate keys, unsafe numbers and surrogates fail.
    public static func decode(_ data: Data) -> ReadResult {
        guard data.count <= byteLimit else { return .refused }
        guard let parsed = try? JSONParser.parse(data), parsed.safety.isSafe,
              let object = parsed.value.objectValue,
              let version = object["format_version"]?.stringValue,
              !version.isEmpty, version.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return .malformed }
        guard version == "0" else { return .unsupportedVersion }
        guard let id = object["binder_id"]?.stringValue, id.utf8.count == 36,
              let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { return .malformed }
        let bytes = Array(id.utf8)
        guard bytes[14] == UInt8(ascii: "4"), "89ab".utf8.contains(bytes[19]) else { return .malformed }
        return .claim(BinderIdentityClaim(binderID: id))
    }
}
