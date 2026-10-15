import Foundation
import SpravaKit

/// No rejected bytes, names or content are included in protocol errors.
public enum CompanionWireError: Error, Equatable { case invalid }

public enum CompanionWire {
    public static func base64(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ text: String) throws -> Data {
        guard text.utf8.count <= 1048576, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || $0 == 45 || $0 == 95 }), text.utf8.count % 4 != 1 else { throw CompanionWireError.invalid }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") +
            String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), base64(bytes) == text else { throw CompanionWireError.invalid }
        return bytes
    }
    public static func isID(_ text: String) -> Bool { text.utf8.count == 22 && (try? decode(text).count) == 16 }
    public static func unsigned(_ value: JSONValue?) -> Int64? {
        guard let number = value?.numberValue, !number.text.hasPrefix("-"), let n = number.safeInteger, n >= 0 else { return nil }
        return n
    }
    /// The shared binder parser is stricter here: refuse its safety warnings and enforce the wire's depth 16.
    public static func parse(_ bytes: Data, limit: Int) throws -> JSONValue {
        guard limit >= 0, bytes.count <= limit else { throw CompanionWireError.invalid }
        do {
            let parsed = try JSONParser.parse(bytes)
            guard parsed.safety.isSafe, depth(parsed.value, 0) else { throw CompanionWireError.invalid }
            return parsed.value
        } catch { throw CompanionWireError.invalid }
    }
    private static func depth(_ value: JSONValue, _ count: Int) -> Bool {
        switch value {
        case .array(let values): count < 16 && values.allSatisfy { depth($0, count + 1) }
        case .object(let object): count < 16 && object.entries.allSatisfy { depth($0.value, count + 1) }
        default: true
        }
    }
}
