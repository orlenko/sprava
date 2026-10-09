import Darwin
import Foundation
import SpravaKit

/// The states of binder-v0 §9.6, most restrictive first.
public enum TekaState: Int, Sendable, Comparable, CaseIterable {
    case notATeka, corrupt, unknownLevel, needsAttention, needsMigration, ready

    public static func < (lhs: TekaState, rhs: TekaState) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .notATeka: "not a binder"
        case .corrupt: "corrupt"
        case .unknownLevel: "unknown level"
        case .needsAttention: "needs attention"
        case .needsMigration: "needs migration"
        case .ready: "ready"
        }
    }
}

/// A binder read from disk, read-only. Reading never writes anything inside the folder.
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

    /// A symlink problem, unsafe JSON, a broken stamp or an op log that cannot be read blocks every write until the
    /// person approves a repair; a name mismatch also blocks publishing and draining (binder-v0 §9.6).
    public var writesBlocked: Bool {
        state < .needsAttention || (states[.needsAttention] ?? []).contains { r in
            r.contains("symbolic link") || r.contains("is not a regular") || r.contains("unsafe JSON")
                || r.hasPrefix("broken stamp") || r == "catalog.json unreadable" || r == ".sprava/ops.ndjson unreadable"
                || r == Self.tooLarge
        }
    }

    public var federationBlocked: Bool {
        writesBlocked || (states[.needsAttention] ?? []).contains("the folder name differs from meta.name")
            || !HubLane.isSafeSegment(name)
    }

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

    /// What `.sprava/ops.ndjson` holds (binder-v0 §6.9). Adopted once it holds a whole line: a log a crash during
    /// adoption left empty or torn is not, so Adopt is offered again (adoption reads such a log as empty and cuts
    /// the torn tail). A log that is there but cannot be read is never taken for an absent one.
    enum OpLog: Equatable {
        case absent, incomplete, complete
        /// `.sprava` or the log is a link, a special file or a folder; nothing was read through it.
        case notRegular(symlink: Bool)
        case unreadable
    }

    /// Reads the op log without following a link anywhere inside the binder and without blocking: `.sprava` is
    /// opened as a real folder first, the log with `O_NONBLOCK`, and anything but a regular file is refused before
    /// a byte is read, so a FIFO cannot hang the read.
    static func opLog(in folder: URL) -> OpLog {
        let dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
        guard dir >= 0 else { return errno == ENOENT ? .absent : .unreadable }
        defer { close(dir) }
        let sprava = openat(dir, ".sprava", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sprava >= 0 else {
            switch errno {
            case ENOENT: return .absent
            case ELOOP, ENOTDIR:
                // macOS answers ENOTDIR for a link under O_DIRECTORY | O_NOFOLLOW; lstat tells them apart.
                var st = stat()
                let link = fstatat(dir, ".sprava", &st, AT_SYMLINK_NOFOLLOW) == 0 && st.st_mode & S_IFMT == S_IFLNK
                return .notRegular(symlink: link)
            default: return .unreadable
            }
        }
        defer { close(sprava) }
        let fd = openat(sprava, "ops.ndjson", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: return .absent
            case ELOOP: return .notRegular(symlink: true)
            default: return .unreadable
            }
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .unreadable }
        guard st.st_mode & S_IFMT == S_IFREG else { return .notRegular(symlink: false) }
        let size = Int64(st.st_size)
        guard size > 0 else { return .incomplete }
        let chunk: Int64 = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: Int(chunk))
        /// Whether the bytes from `offset` up to `count` hold a newline; nil when a read fails or comes up short.
        func newline(at offset: Int64, count: Int64) -> Bool? {
            var done: Int64 = 0
            while done < count {
                let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(count - done), off_t(offset + done)) }
                if n < 0 { if errno == EINTR { continue }; return nil }
                if n == 0 { return nil }
                if buffer[0..<n].contains(0x0A) { return true }
                done += Int64(n)
            }
            return false
        }
        // The tail first: one read for any log whose last line is short.
        let tailStart = max(0, size - chunk)
        switch newline(at: tailStart, count: size - tailStart) {
        case nil: return .unreadable
        case true?: return .complete
        case false?: break
        }
        var offset: Int64 = 0
        while offset < tailStart {
            switch newline(at: offset, count: min(chunk, tailStart - offset)) {
            case nil: return .unreadable
            case true?: return .complete
            case false?: offset += chunk
            }
        }
        return .incomplete
    }

    /// The largest `catalog.json` read: the whole file is held in memory to parse it, so a huge or sparse one
    /// must not exhaust memory before it is found invalid.
    static let maxCatalogBytes = 64 << 20
    static let tooLarge = "catalog.json is larger than 64 MiB"

    /// The bytes of a regular file directly in the binder folder, opened without following a link or blocking on
    /// a special file; nil for anything else, or for a file longer than `limit` bytes.
    static func readRegular(_ name: String, in folder: URL, limit: Int = maxCatalogBytes) -> Data? {
        let dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
        guard dir >= 0 else { return nil }
        defer { close(dir) }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= limit else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return data }
            if data.count + n > limit { return nil }      // it grew after the fstat
            data.append(contentsOf: buffer[0..<n])
        }
    }

    /// Reads the folder. Never throws: a problem becomes a state.
    public static func read(_ folder: URL) -> Teka {
        let fm = FileManager.default
        let catalogURL = folder.appendingPathComponent("catalog.json")
        var states: [TekaState: [String]] = [:]
        func flag(_ state: TekaState, _ reason: String) { states[state, default: []].append(reason) }

        // Containment: these must be regular files or folders, never symlinks (binder-v0 §3.6).
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

        // The op log, read only through a real `.sprava` folder. Anything standing where history lives counts as
        // adopted, so Adopt is never offered over it, and blocks writes until it is repaired.
        let history = opLog(in: folder)
        let adopted = history != .absent && history != .incomplete
        if states[.needsAttention]?.contains(where: { $0.hasPrefix(".sprava is") }) != true {
            switch history {
            case .notRegular(let symlink):
                flag(.needsAttention, symlink ? ".sprava/ops.ndjson is a symbolic link" : ".sprava/ops.ndjson is not a regular file")
            case .unreadable: flag(.needsAttention, ".sprava/ops.ndjson unreadable")
            default: break
            }
        }

        // Only a catalog that is not there makes a folder not a binder; one that cannot be looked at (a folder
        // without search permission, an I/O error) is unreadable, and the findings above are kept.
        func blocked(_ reason: String, modified: Date?) -> Teka {
            Teka(folder: folder, states: states.merging([.needsAttention: [reason]]) { $0 + $1 },
                 level: nil, catalog: nil, safety: .init(), findings: [], isAdopted: adopted, modified: modified)
        }
        var st = stat()
        guard lstat(catalogURL.path, &st) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return Teka(folder: folder, states: [.notATeka: ["no catalog.json"]], level: nil, catalog: nil,
                            safety: .init(), findings: [], isAdopted: adopted, modified: nil)
            }
            return blocked("catalog.json unreadable", modified: nil)
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        let contained = states[.needsAttention]?.contains(where: { $0.hasPrefix("catalog.json") }) != true
        if contained, st.st_size > maxCatalogBytes { return blocked(tooLarge, modified: modified) }
        guard contained, let data = readRegular("catalog.json", in: folder) else {
            return blocked("catalog.json unreadable", modified: modified)
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
        case .lifeprojV1, .lifeprojV2: flag(.needsMigration, "not yet stamped binder v0")
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

        // The generic rule on the core arrays (binder-v0 §4.1): every entry is an object, and among entries that
        // carry an id, ids are unique by JSON type and value. Two ids are the same only when both match.
        for key in ["documents", "open_items", "processing_log"] {
            let entries = catalog[key]?.arrayValue ?? []
            if entries.contains(where: { $0.objectValue == nil }) {
                flag(.needsMigration, "\(key) holds entries that are not objects")
            }
            var seen = Set<JSONValue>()
            var duplicate = false
            for entry in entries {
                guard let id = entry["id"] else { continue }
                if !seen.insert(id).inserted { duplicate = true }
            }
            if duplicate { flag(.needsMigration, "duplicate ids in \(key)") }
        }

        // v0 meta (binder-v0 §4.2): name and disclosure are required once stamped, and the typed fields are checked.
        let stamped = level == .tekaV0 || level == .tekaV0BadSchemaVersion
        if stamped, case .object(let meta)? = catalog["meta"] {
            if (meta["name"]?.stringValue ?? "").isEmpty { flag(.needsAttention, "stamped catalog without meta.name") }
            switch meta["disclosure"]?.stringValue {
            case "full"?, "title"?, "kind"?, "none"?: break
            default: flag(.needsAttention, "stamped catalog without a valid meta.disclosure")
            }
            if let lifecycle = meta["lifecycle"], !["ongoing", "finite"].contains(lifecycle.stringValue ?? "") {
                flag(.needsAttention, "meta.lifecycle is not ongoing or finite")
            }
            if let created = meta["created"], created.stringValue.flatMap(CalendarDate.strict) == nil {
                flag(.needsAttention, "meta.created is not a YYYY-MM-DD date")
            }
            if let scheme = meta["id_scheme"], !["teka-year-seq", "opaque"].contains(scheme.stringValue ?? "") {
                flag(.needsAttention, "meta.id_scheme is not teka-year-seq or opaque")
            }
            for key in ["modules", "active_chapters"] {
                if let list = meta[key], list.arrayValue?.allSatisfy({ $0.stringValue != nil }) != true {
                    flag(.needsAttention, "meta.\(key) is not a list of strings")
                }
            }
        }

        // Name (binder-v0 §3.1).
        if case .string(let name)? = catalog["meta"]?["name"],
           name.precomposedStringWithCanonicalMapping != folder.lastPathComponent.precomposedStringWithCanonicalMapping {
            flag(.needsAttention, "the folder name differs from meta.name")
        }

        var findings: [RuleFinding] = []
        if level.strictItems {
            findings = ItemRules.check(items: catalog["open_items"]?.arrayValue ?? [],
                                       log: catalog["processing_log"]?.arrayValue ?? [],
                                       v0: stamped)
            if !findings.isEmpty {
                flag(stamped && adopted ? .needsAttention : .needsMigration,
                     "\(findings.count) rule failure(s) in open_items")
            }
        }
        // Stamped document records have their v0 fields (binder-v0 §4.3); a legacy record is reported at adoption.
        if stamped {
            let failures = ItemRules.check(documents: catalog["documents"]?.arrayValue ?? [])
            if !failures.isEmpty {
                flag(adopted ? .needsAttention : .needsMigration, "\(failures.count) rule failure(s) in documents")
                findings += failures
            }
        }

        return Teka(folder: folder, states: states, level: level, catalog: catalog, safety: parsed.safety,
                    findings: findings, isAdopted: adopted, modified: modified)
    }
}
