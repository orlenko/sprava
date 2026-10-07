import Foundation

/// The states of teka-v0 §9.6, most restrictive first.
public enum TekaState: Int, Sendable, Comparable, CaseIterable {
    case notATeka, corrupt, unknownLevel, needsAttention, needsMigration, ready

    public static func < (lhs: TekaState, rhs: TekaState) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .notATeka: "not a teka"
        case .corrupt: "corrupt"
        case .unknownLevel: "unknown level"
        case .needsAttention: "needs attention"
        case .needsMigration: "needs migration"
        case .ready: "ready"
        }
    }
}

/// A teka read from disk, read-only. Reading never writes anything inside the folder.
public struct Teka: Sendable {
    public let folder: URL
    /// Every state that applies; `state` is the most restrictive.
    public let states: [TekaState: [String]]
    public let level: CatalogLevel?
    public let catalog: JSONObject?
    public let safety: JSONSafetyReport
    public let findings: [RuleFinding]
    /// True when a full implementation has adopted it (its op log exists).
    public let isAdopted: Bool
    /// When `catalog.json` last changed on disk.
    public let modified: Date?

    public var state: TekaState { states.keys.min() ?? .ready }
    public var reasons: [String] { states.sorted { $0.key < $1.key }.flatMap(\.value) }

    public var name: String {
        if case .string(let n)? = catalog?["meta"]?["name"], !n.isEmpty { return n }
        return folder.lastPathComponent
    }

    public var items: [Item] {
        (catalog?["open_items"]?.arrayValue ?? []).enumerated().map { Item(raw: $1, index: $0) }
    }

    public var log: [LogEntry] {
        (catalog?["processing_log"]?.arrayValue ?? []).map { LogEntry(raw: $0) }
    }

    public func nowPage(today: CalendarDate, timeZone: TimeZone = .current) -> NowPage {
        NowPage(items: items, log: log, today: today, timeZone: timeZone)
    }

    /// Reads the folder. Never throws: a problem becomes a state.
    public static func read(_ folder: URL) -> Teka {
        let fm = FileManager.default
        let catalogURL = folder.appendingPathComponent("catalog.json")
        var states: [TekaState: [String]] = [:]
        func flag(_ state: TekaState, _ reason: String) { states[state, default: []].append(reason) }

        let adopted = fm.fileExists(atPath: folder.appendingPathComponent(".sprava/ops.ndjson").path)

        // Containment: these must be regular files or folders, never symlinks (teka-v0 §3.6).
        for (name, wantDirectory) in [("catalog.json", false), ("DASHBOARD.md", false), (".teka.lock", false), (".sprava", true)] {
            let path = folder.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                flag(.needsAttention, "\(name) is a symbolic link")
            } else if wantDirectory ? type != .typeDirectory : type != .typeRegular {
                flag(.needsAttention, "\(name) is not a regular \(wantDirectory ? "folder" : "file")")
            }
        }

        guard let attrs = try? fm.attributesOfItem(atPath: catalogURL.path) else {
            return Teka(folder: folder, states: [.notATeka: ["no catalog.json"]], level: nil, catalog: nil,
                        safety: .init(), findings: [], isAdopted: adopted, modified: nil)
        }
        let modified = attrs[.modificationDate] as? Date
        guard states[.needsAttention]?.contains(where: { $0.hasPrefix("catalog.json") }) != true,
              let data = try? Data(contentsOf: catalogURL) else {
            return Teka(folder: folder, states: states.merging([.needsAttention: ["catalog.json unreadable"]]) { $0 + $1 },
                        level: nil, catalog: nil, safety: .init(), findings: [], isAdopted: adopted, modified: modified)
        }

        let parsed: (value: JSONValue, safety: JSONSafetyReport)
        do {
            parsed = try JSONParser.parse(data)
        } catch {
            return Teka(folder: folder, states: [.corrupt: ["catalog.json: \(error)"]], level: nil, catalog: nil,
                        safety: .init(), findings: [], isAdopted: adopted, modified: modified)
        }
        guard case .object(let catalog) = parsed.value else {
            return Teka(folder: folder, states: [.corrupt: ["catalog.json is not a JSON object"]], level: nil,
                        catalog: nil, safety: parsed.safety, findings: [], isAdopted: adopted, modified: modified)
        }

        if !parsed.safety.isSafe {
            flag(.needsAttention, "catalog.json holds unsafe JSON (duplicate keys, lone surrogates or out-of-range numbers)")
        }

        let level = CatalogLevel.classify(catalog)
        switch level {
        case .unknown(let why): flag(.unknownLevel, why)
        case .brokenStamp: flag(.needsAttention, "broken stamp: meta.format_version is missing or not digits")
        case .tekaV0BadSchemaVersion: flag(.needsAttention, "stamped catalog whose schema_version is not 2")
        case .preLifeproj: flag(.needsMigration, "pre-lifeproj catalog")
        case .lifeprojV1, .lifeprojV2: flag(.needsMigration, "not yet stamped teka v0")
        case .tekaV0: break
        }

        // Core arrays.
        for key in ["documents", "open_items", "processing_log"] {
            switch catalog[key] {
            case nil:
                if level == .tekaV0 { flag(.needsMigration, "\(key) is missing") }
            case .array?: break
            default: flag(.needsMigration, "\(key) is not an array")
            }
        }

        // Generic unique-id rule on the core arrays (teka-v0 §4.1).
        for key in ["documents", "processing_log"] {
            let ids = (catalog[key]?.arrayValue ?? []).compactMap { ItemID($0["id"]) }
            if Set(ids).count != ids.count {
                flag(.needsMigration, "duplicate ids in \(key)")
            }
        }

        // Name (teka-v0 §3.1).
        if case .string(let name)? = catalog["meta"]?["name"],
           name.precomposedStringWithCanonicalMapping != folder.lastPathComponent.precomposedStringWithCanonicalMapping {
            flag(.needsAttention, "the folder name differs from meta.name")
        }

        var findings: [RuleFinding] = []
        if level.strictItems {
            findings = ItemRules.check(items: catalog["open_items"]?.arrayValue ?? [],
                                       log: catalog["processing_log"]?.arrayValue ?? [],
                                       v0: level == .tekaV0)
            if !findings.isEmpty {
                flag(level == .tekaV0 && adopted ? .needsAttention : .needsMigration,
                     "\(findings.count) rule failure(s) in open_items")
            }
        }

        return Teka(folder: folder, states: states, level: level, catalog: catalog, safety: parsed.safety,
                    findings: findings, isAdopted: adopted, modified: modified)
    }
}
