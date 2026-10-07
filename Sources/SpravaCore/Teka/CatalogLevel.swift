import Foundation

/// The catalog level, read from the values as written in the file (teka-v0 §9.6, the level table).
public enum CatalogLevel: Sendable, Equatable {
    case lifeprojV2
    case lifeprojV1
    /// No `meta` object, no `schema_version`, or `schema_version` an integer below 1.
    case preLifeproj
    case tekaV0
    /// `format` is `teka` but `schema_version` is not the integer 2: a repair proposal fixes it.
    case tekaV0BadSchemaVersion
    /// `format` is `teka` but `format_version` is missing or not digits.
    case brokenStamp
    /// A newer or foreign level; the reason says which.
    case unknown(String)

    public static func classify(_ catalog: JSONObject) -> CatalogLevel {
        guard case .object(let meta)? = catalog["meta"] else { return .preLifeproj }
        let schema = meta["schema_version"]
        if let format = meta["format"] {
            guard format == .string("teka") else { return .unknown("meta.format is not \"teka\"") }
            guard case .string(let fv)? = meta["format_version"], !fv.isEmpty, fv.allSatisfy(\.isASCIIDigitChar) else {
                return .brokenStamp
            }
            guard fv == "0" else { return .unknown("written by a newer version (format_version \(fv))") }
            if case .number(let n)? = schema, n.isIntegerLiteral, n.safeInteger == 2 { return .tekaV0 }
            return .tekaV0BadSchemaVersion
        }
        switch schema {
        case nil:
            return .preLifeproj
        case .number(let n)?:
            if n.isIntegerLiteral {
                guard let value = n.safeInteger else { return .unknown("schema_version out of range") }
                switch value {
                case ..<1: return .preLifeproj
                case 1: return .lifeprojV1
                case 2: return .lifeprojV2
                default: return .unknown("schema_version \(value)")
                }
            }
            return .lifeprojV1   // 2.0 and the like: lifeproj's checker treats a non-integer as legacy
        case .string(let s)? where !s.isEmpty && s.allSatisfy(\.isASCIIDigitChar):
            return .lifeprojV1
        default:
            return .unknown("schema_version is \(schema!.typeName)")
        }
    }

    /// Whether lifeproj's strict v2 item rules apply.
    public var strictItems: Bool {
        switch self {
        case .lifeprojV2, .tekaV0, .tekaV0BadSchemaVersion: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .lifeprojV2: "lifeproj v2"
        case .lifeprojV1: "lifeproj v1"
        case .preLifeproj: "pre-lifeproj"
        case .tekaV0: "teka v0"
        case .tekaV0BadSchemaVersion: "teka v0 (bad schema_version)"
        case .brokenStamp: "teka v0 (broken stamp)"
        case .unknown(let why): "unknown level: \(why)"
        }
    }
}

extension Character {
    var isASCIIDigitChar: Bool { isASCII && isNumber }
}
