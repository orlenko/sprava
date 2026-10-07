import Darwin
import Foundation

/// The intake watcher (mvp.md feature 4): each adopted binder's `intake/` folder, top level only. A file that
/// holds still between two scans becomes a Tier 0 card proposing `file_document` in its intake form. Code reads
/// the file's name, date, size and digest and nothing else: no text, no helper, no model.
public struct IntakeWatcher: Sendable {
    public let support: URL

    public init(support: URL) { self.support = support }

    var stateURL: URL { support.appendingPathComponent("capture/intake.json") }

    struct Seen: Codable, Equatable {
        var size: Int
        var mtime: Double
        var card: String?
        var firstSeen: Date
    }

    func load() -> [String: [String: Seen]] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: stateURL)).flatMap { try? decoder.decode([String: [String: Seen]].self, from: $0) } ?? [:]
    }

    func save(_ s: [String: [String: Seen]]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? AtomicFile.makePrivateFolder(stateURL.deletingLastPathComponent())
        if let data = try? encoder.encode(s) { try? AtomicFile.write(data, to: stateURL) }
    }

    public struct ScanResult: Equatable, Sendable {
        public var carded = 0
        public var waiting = 0
        public var replaced = 0
        /// Files that sat in some intake/ for more than 7 days without being filed (mvp.md 1.2, currency).
        public var stale = 0
    }

    /// The files of `intake/` worth a card: plain files of this user, not dot names, not `_converted/` or `mail/`.
    public static func candidates(in folder: URL) -> [(name: String, size: Int, mtime: Double)] {
        let intake = folder.appendingPathComponent("intake")
        var st = stat()
        guard lstat(intake.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
              let names = try? FileManager.default.contentsOfDirectory(atPath: intake.path) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix("."), !["_converted", "mail"].contains(name), DocumentPaths.isIntake("intake/" + name) else { return nil }
            var s = stat()
            guard lstat(intake.appendingPathComponent(name).path, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid() else { return nil }
            return (name, Int(s.st_size), Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9)
        }
    }

    /// One pass over the binders this Mac manages.
    public func scan(binders: [ShelfRow], commands: Commands, now: Date = Date(), digests: [String: String] = [:]) -> ScanResult {
        var result = ScanResult()
        var state = load()
        // Binders not scanned this time keep their state, so a binder briefly missing is never carded again.
        var kept = state
        for row in binders where row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == commands.deviceID {
            let key = row.folder.standardizedFileURL.path
            var seen = state[key] ?? [:]
            var next: [String: Seen] = [:]
            // Cards already waiting for a file, matched by name and digest, are never made twice.
            let waiting = ProposalStore.list(in: row.folder).map(\.0).filter { $0.state == "proposed" && $0.raw["provenance"]?["intake"] != nil }
            for file in Self.candidates(in: row.folder) {
                var entry = seen.removeValue(forKey: file.name)
                if let e = entry, e.size == file.size, e.mtime == file.mtime {
                    if e.card == nil {
                        let path = row.folder.appendingPathComponent("intake/" + file.name).path
                        let sha = digests[path] ?? DocumentPaths.sha256(of: URL(fileURLWithPath: path))
                        if let existing = waiting.first(where: { $0.raw["provenance"]?["intake"]?["name"]?.stringValue == file.name
                            && $0.raw["provenance"]?["intake"]?["sha256"]?.stringValue == sha }) {
                            entry?.card = existing.id
                        } else {
                            entry?.card = card(file, sha: sha, in: row, commands: commands, now: now)
                            if entry?.card != nil { result.carded += 1 }
                        }
                    } else if now.timeIntervalSince(e.firstSeen) > 7 * 86_400 {
                        result.stale += 1
                    }
                } else {
                    // New, or still being written, or changed after its card: wait for it to hold still. A card for
                    // the old bytes is withdrawn; its digest would be refused on approval anyway.
                    if let old = entry?.card {
                        withdraw(old, in: row.folder, now: now)
                        result.replaced += 1
                    }
                    entry = Seen(size: file.size, mtime: file.mtime, card: nil, firstSeen: entry?.firstSeen ?? now)
                    result.waiting += 1
                }
                next[file.name] = entry
            }
            // Files gone from intake/ (filed, or removed by the person): cards still waiting for them are withdrawn.
            for (_, gone) in seen { if let card = gone.card { withdraw(card, in: row.folder, now: now) } }
            kept[key] = next
        }
        save(kept)
        return result
    }

    /// The files the next scan would card: they held still since the last scan and have no card yet. Their
    /// digests are computed by the caller off the command queue, so a large file never stalls the app.
    public func filesToHash(binders: [ShelfRow], deviceID: String) -> [URL] {
        let state = load()
        var out: [URL] = []
        for row in binders where row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == deviceID {
            let seen = state[row.folder.standardizedFileURL.path] ?? [:]
            for file in Self.candidates(in: row.folder) {
                if let e = seen[file.name], e.card == nil, e.size == file.size, e.mtime == file.mtime {
                    out.append(row.folder.appendingPathComponent("intake/" + file.name))
                }
            }
        }
        return out
    }

    /// The suggested folder: where most of the binder's documents already live, else `documents`.
    static func suggestedFolder(_ catalog: JSONObject?) -> String {
        var counts: [String: Int] = [:]
        for doc in catalog?["documents"]?.arrayValue ?? [] {
            guard let path = doc["path"]?.stringValue, path.contains("/") else { continue }
            let parent = (path as NSString).deletingLastPathComponent
            if DocumentPaths.isSafe(parent + "/x") { counts[parent, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? "documents"
    }

    /// A free destination name in `folder`: `name`, else `name (2)`, `name (3)`, and so on.
    static func freePath(_ folder: String, _ name: String, in binder: URL) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var candidate = "\(folder)/\(name)"
        var n = 2
        while !DocumentPaths.isFreeDestination(candidate, in: binder) && n < 1000 {
            candidate = "\(folder)/\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            n += 1
        }
        return candidate
    }

    func card(_ file: (name: String, size: Int, mtime: Double), sha: String?, in row: ShelfRow, commands: Commands, now: Date) -> String? {
        let from = "intake/" + file.name
        guard let sha else { return nil }
        let safe = DocumentPaths.safeName(file.name)
        let path = Self.freePath(Self.suggestedFolder(row.teka.catalog), safe, in: row.folder)
        let modified = Date(timeIntervalSince1970: file.mtime)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.dateComponents([.year, .month, .day], from: modified)
        var document = JSONObject()
        document.set("id", .str("$new:1"))
        document.set("title", .string((safe as NSString).deletingPathExtension.isEmpty ? safe : (safe as NSString).deletingPathExtension))
        document.set("path", .string(path))
        document.set("sha256", .string(sha))
        document.set("source", .str("intake/"))
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)),
                                (key: "model", value: .str("none"))])
        let op = JSONObject([(key: "op", value: .str("file_document")),
                             (key: "args", value: .obj([("document", .object(document)), ("from", .string(from))]))])
        let provenance = JSONObject([
            (key: "intake", value: .obj([("name", .string(file.name)), ("bytes", .int(file.size)),
                                         ("modified", .string(String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0))),
                                         ("sha256", .string(sha))])),
            (key: "filed_by", value: .str("code, no model")),
        ])
        let proposal = Proposal.make(title: "File \u{201C}\(safe)\u{201D} from intake", actor: actor, ops: [op], provenance: provenance, now: now)
        do {
            try ProposalStore.save(proposal, in: row.folder)
            commands.trustProposals([proposal.id], in: row.folder)
            return proposal.id
        } catch {
            return nil
        }
    }

    func withdraw(_ id: String, in folder: URL, now: Date) {
        guard let (proposal, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == id }), proposal.state == "proposed" else { return }
        try? TekaStore(folder: folder).reject(proposal, reason: "the file in intake/ changed or is gone", now: now)
    }
}
