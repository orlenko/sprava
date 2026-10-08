import Darwin
import Foundation

/// The intake watcher (mvp.md feature 4; docs/adaptation-layer.md §4): each adopted binder's `intake/` folder,
/// top level, plus the messages a mail monitor writes to `intake/mail/`. A file that holds still between two scans
/// is read in the sandboxed helper (off the command queue, by `prepare`) and becomes a Tier 0 card proposing
/// `file_document`, with what code found in it; the clerk's document reading may then replace the card.
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

    /// The cursor: empty only when `intake.json` does not exist. One that cannot be read or decoded throws, so it is
    /// never saved over: rebuilt, it would card again every file the person already rejected (capture-event-v0 §5.3).
    func load() throws -> [String: [String: Seen]] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try OwnState.read([String: [String: Seen]].self, from: stateURL, decoder: decoder) ?? [:]
    }

    func save(_ s: [String: [String: Seen]]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFile.makePrivateFolder(stateURL.deletingLastPathComponent())
        try AtomicFile.write(try encoder.encode(s), to: stateURL)
    }

    public struct ScanResult: Equatable, Sendable {
        public var carded = 0
        public var waiting = 0
        public var replaced = 0
        public var held = 0
        /// Files that sat in some intake/ for more than 7 days without being filed (mvp.md 1.2, currency).
        public var stale = 0
        /// The cursor could not be written: every file would look new on every scan, so the job reports it.
        public var cursorUnsaved = false
        /// The cursor exists but cannot be read: nothing was scanned, and nothing was written over it.
        public var cursorUnreadable = false
    }

    /// One thing in `intake/` worth a card: a file, or a message with the files of its attachments folder.
    public struct Candidate: Sendable, Equatable {
        public var name: String              // relative to intake/
        public var size: Int                 // all its files together
        public var mtime: Double             // the latest of them
        public var attachments: [String] = []   // relative to intake/
        public var channel = "other"
    }

    static func plainFile(_ url: URL) -> (size: Int, mtime: Double)? {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid() else { return nil }
        return (Int(s.st_size), Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9)
    }

    static func folderTime(_ url: URL) -> Double? {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid() else { return nil }
        return Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9
    }

    /// The files of `intake/` worth a card: plain files of this user, not dot names, not `_converted/`; and in
    /// `mail/`, each message (`.md` from a mail monitor, or `.eml`) with its `<name> attachments/` folder.
    /// A mail monitor's `.env` and `state.json` are never read (binder-v0 §3.3).
    public static func candidates(in folder: URL) -> [Candidate] {
        let intake = folder.appendingPathComponent("intake")
        guard folderTime(intake) != nil, let names = try? FileManager.default.contentsOfDirectory(atPath: intake.path) else { return [] }
        var out: [Candidate] = names.sorted().compactMap { name in
            guard !name.hasPrefix("."), !["_converted", "mail"].contains(name), DocumentPaths.isIntake("intake/" + name),
                  let f = plainFile(intake.appendingPathComponent(name)) else { return nil }
            return Candidate(name: name, size: f.size, mtime: f.mtime)
        }
        let mail = intake.appendingPathComponent("mail")
        guard folderTime(mail) != nil, let messages = try? FileManager.default.contentsOfDirectory(atPath: mail.path) else { return out }
        for name in messages.sorted() {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["md", "eml"].contains(ext), !name.hasPrefix("."), DocumentPaths.isIntake("intake/mail/" + name),
                  let f = plainFile(mail.appendingPathComponent(name)) else { continue }
            var c = Candidate(name: "mail/" + name, size: f.size, mtime: f.mtime, channel: "email")
            let stem = (name as NSString).deletingPathExtension
            for folderName in [stem + " attachments", name + " attachments"] {
                let dir = mail.appendingPathComponent(folderName)
                guard let t = folderTime(dir), let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
                c.mtime = max(c.mtime, t)
                for file in files.sorted() where !file.hasPrefix(".") && DocumentPaths.isIntake("intake/mail/\(folderName)/\(file)") {
                    guard let a = plainFile(dir.appendingPathComponent(file)) else { continue }
                    c.size += a.size
                    c.mtime = max(c.mtime, a.mtime)
                    c.attachments.append("mail/\(folderName)/\(file)")
                }
                break
            }
            out.append(c)
        }
        return out
    }

    /// What `scan` needs that is slow: digests of every file and the readings, computed off the command queue.
    public struct Prepared: Sendable {
        public var digests: [String: String] = [:]
        public var readings: [String: IntakeReading] = [:]
        public init() {}
    }

    /// Reads the files the next scan would card: they held still since the last scan and have no card yet. At
    /// most `budget` seconds of reading per call; the rest wait for the next one. The runtime passes the located
    /// helper; a missing one holds each file with a card that says so.
    public func prepare(binders: [ShelfRow], deviceID: String, reader: ExtractHelper.Reader, read: Bool = true,
                        budget: TimeInterval = 240) -> Prepared {
        // A cursor that cannot be read names no file as held still: nothing is read (scan reports it).
        guard let state = try? load() else { return Prepared() }
        let started = Date()
        var out = Prepared()
        for row in binders where row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == deviceID {
            let seen = state[row.folder.standardizedFileURL.path] ?? [:]
            for c in Self.candidates(in: row.folder) {
                guard let e = seen[c.name], e.card == nil, e.size == c.size, e.mtime == c.mtime else { continue }
                if read && Date().timeIntervalSince(started) > budget { return out }
                let file = row.folder.appendingPathComponent("intake/" + c.name)
                let attachments = c.attachments.map { row.folder.appendingPathComponent("intake/" + $0) }
                for url in [file] + attachments { out.digests[url.path] = DocumentPaths.sha256(of: url) }
                if read { out.readings[file.path] = IntakeReading.read(file, attachments: attachments, channel: c.channel, reader: reader) }
            }
        }
        return out
    }

    /// One pass over the binders this Mac manages. With `requireReading`, a file is carded only once `prepare`
    /// has read it, so every card shows what the file says.
    public func scan(binders: [ShelfRow], commands: Commands, now: Date = Date(), prepared: Prepared = Prepared(),
                     requireReading: Bool = false) -> ScanResult {
        var result = ScanResult()
        guard let state = try? load() else {
            result.cursorUnreadable = true
            return result
        }
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
                        let reading = prepared.readings[path]
                        if requireReading && reading == nil { result.waiting += 1; next[file.name] = entry; continue }
                        let sha = prepared.digests[path] ?? DocumentPaths.sha256(of: URL(fileURLWithPath: path))
                        let matching = waiting.filter { $0.raw["provenance"]?["intake"]?["name"]?.stringValue == file.name
                            && $0.raw["provenance"]?["intake"]?["sha256"]?.stringValue == sha }
                        // Only a card Sprava recorded is taken over, with its reading made sure of; one it cannot
                        // vouch for could never be approved, so it is withdrawn and the file carded again.
                        if let existing = matching.first(where: { Self.isTrusted($0.id, in: row.folder, commands: commands) }) {
                            entry?.card = existing.id
                            if let sha, IntakeReadings(support: support).forCard(existing.id) == nil {
                                saveReading(reading, file: file, sha: sha, card: existing.id, in: row, now: now)
                            }
                        } else {
                            for stranded in matching { withdraw(stranded.id, in: row.folder, now: now) }
                            entry?.card = card(file, sha: sha, reading: reading, digests: prepared.digests, in: row, commands: commands, now: now)
                            if entry?.card != nil {
                                result.carded += 1
                                if reading?.held != nil { result.held += 1 }
                            }
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
        if (try? save(kept)) == nil { result.cursorUnsaved = true }
        IntakeReadings(support: support).prune(now: now)
        return result
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

    static func day(_ time: Double) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: time))
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// A one-line title from a message subject, or the file name without its extension.
    static func title(_ name: String, subject: String?) -> String {
        let s = (subject ?? "").replacingOccurrences(of: #"^((re|fwd?|tr)\s*:\s*)+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { return Clerk.shorten(s, to: 120) }
        let safe = DocumentPaths.safeName((name as NSString).lastPathComponent)
        let stem = (safe as NSString).deletingPathExtension
        return stem.isEmpty ? safe : stem
    }

    /// The first words of a reading, for the card.
    static func preview(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).prefix(40).joined(separator: " ")
        return flat.count > 240 ? String(flat.prefix(240)) + "\u{2026}" : flat
    }

    func card(_ file: Candidate, sha: String?, reading: IntakeReading?, digests: [String: String], in row: ShelfRow,
              commands: Commands, now: Date) -> String? {
        guard let sha else { return nil }
        let folder = Self.suggestedFolder(row.teka.catalog)
        let isMail = file.name.hasPrefix("mail/")
        var used = Set<String>()
        func destination(_ name: String) -> String {
            var path = Self.freePath(folder, DocumentPaths.safeName((name as NSString).lastPathComponent), in: row.folder)
            var n = 2
            while used.contains(DocumentPaths.fold(path)) && n < 1000 {
                let base = DocumentPaths.safeName((name as NSString).lastPathComponent)
                let ext = (base as NSString).pathExtension
                path = Self.freePath(folder, (base as NSString).deletingPathExtension + " (\(n))" + (ext.isEmpty ? "" : ".\(ext)"), in: row.folder)
                n += 1
            }
            used.insert(DocumentPaths.fold(path))
            return path
        }
        // How it came (docs/adaptation-layer.md §3.3): copied into every document filed from it.
        var obtained = JSONObject([(key: "channel", value: .string(reading?.channel ?? file.channel))])
        if let from = reading?.from { obtained.set("from", .string(Clerk.shorten(from, to: 200))) }
        if let received = IntakeReading.day(ofHeader: reading?.date) { obtained.set("received", .string(received.description)) }
        if let r = reading { obtained.set("text_from", .string(r.textFrom)) }

        var ops: [JSONObject] = []
        var number = 0
        for (index, name) in ([file.name] + file.attachments).enumerated() {
            let fileSHA = index == 0 ? sha : (digests[row.folder.appendingPathComponent("intake/" + name).path]
                ?? DocumentPaths.sha256(of: row.folder.appendingPathComponent("intake/" + name)))
            guard let fileSHA else { return nil }
            number += 1
            var document = JSONObject()
            document.set("id", .string("$new:\(number)"))
            document.set("title", .string(index == 0 ? Self.title(name, subject: reading?.subject) : Self.title(name, subject: nil)))
            document.set("path", .string(destination(name)))
            document.set("sha256", .string(fileSHA))
            if index == 0, let r = reading {
                if r.kind == "email" { document.set("kind", .str("email")) }
                else if r.textFrom == "ocr" { document.set("kind", .str("scan")) }
                if let d = IntakeReading.day(ofHeader: r.date) { document.set("date", .string(d.description)) }
            } else if index > 0 {
                document.set("kind", .str("attachment"))
            }
            document.set("source", .string(isMail ? "intake/mail" : "intake/"))
            document.set("provenance", .obj([("obtained", .object(obtained))]))
            ops.append(JSONObject([(key: "op", value: .str("file_document")),
                                   (key: "args", value: .obj([("document", .object(document)), ("from", .string("intake/" + name))]))]))
        }
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)),
                                (key: "model", value: .str("none"))])
        var intake = JSONObject([(key: "name", value: .string(file.name)), (key: "bytes", value: .int(file.size)),
                                 (key: "modified", value: .string(Self.day(file.mtime))), (key: "sha256", value: .string(sha))])
        if !file.attachments.isEmpty { intake.set("attachments", .int(file.attachments.count)) }
        intake.set("obtained", .object(obtained))
        if let r = reading {
            intake.set("kind", .string(r.kind))
            intake.set("text_from", .string(r.textFrom))
            if let pages = r.pages { intake.set("pages", .int(pages)) }
            if let held = r.held { intake.set("held", .string(held)) }
            if !r.notes.isEmpty { intake.set("notes", .array(r.notes.map(JSONValue.string))) }
            if r.mismatch { intake.set("mismatch", .bool(true)) }
            if r.held == nil, !r.text.isEmpty {
                intake.set("preview", .string(Self.preview(r.text)))
                let anchor = IntakeReading.day(ofHeader: r.date) ?? CalendarDate.today(now: now)
                intake.set("facts", IntakeFacts.of(r, anchor: anchor).json)
            }
        }
        let provenance = JSONObject([(key: "intake", value: .object(intake)), (key: "filed_by", value: .str("code, no model"))])
        let shown = Self.title(file.name, subject: reading?.subject)
        let title: String
        if reading?.held != nil { title = "Held: \u{201C}\(shown)\u{201D} was not read" }
        else if isMail { title = "File the email \u{201C}\(shown)\u{201D}" + (file.attachments.isEmpty ? "" : " and \(file.attachments.count) attachment(s)") }
        else { title = "File \u{201C}\(DocumentPaths.safeName(file.name))\u{201D} from intake" }
        let proposal = Proposal.make(title: title, actor: actor, ops: ops, provenance: provenance, now: now)
        do {
            try ProposalStore.save(proposal, in: row.folder)
        } catch {
            return nil
        }
        do {
            try commands.trustProposals([proposal.id], in: row.folder)
        } catch {
            // A card whose digest was not kept could never be approved: it goes, and the file stays uncarded, so the
            // next scan cards it again.
            let written = ProposalStore.dir(row.folder).appendingPathComponent("\(proposal.id).json")
            if (try? FileManager.default.removeItem(at: written)) == nil { withdraw(proposal.id, in: row.folder, now: now) }
            return nil
        }
        saveReading(reading, file: file, sha: sha, card: proposal.id, in: row, now: now)
        return proposal.id
    }

    /// A reading with text waits for the clerk's document reading (§4.2, §4.3).
    func saveReading(_ reading: IntakeReading?, file: Candidate, sha: String, card: String, in row: ShelfRow, now: Date) {
        guard let r = reading, r.held == nil, !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let entry = IntakeReadings.Entry(id: UUIDv7.make(now: now), binder: row.folder.standardizedFileURL.path, name: file.name,
                                         sha256: sha, card: card, reading: r, now: now)
        IntakeReadings(support: support).save(entry)
    }

    /// Whether the binder holds this card as Sprava last wrote it (its recorded digest matches).
    static func isTrusted(_ id: String, in folder: URL, commands: Commands) -> Bool {
        guard let trusted = try? commands.loadDigests(),
              let (_, digest) = ProposalStore.list(in: folder).first(where: { $0.0.id == id }) else { return false }
        return [folder, folder.standardizedFileURL].contains { trusted[commands.key($0, id)] == digest }
    }

    func withdraw(_ id: String, in folder: URL, now: Date) {
        let readings = IntakeReadings(support: support)
        if var e = readings.forCard(id), e.state != "read" {
            e.state = "gone"
            if e.escalation == "waiting" { e.escalation = nil }
            readings.save(e)
        }
        guard let (proposal, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == id }), proposal.state == "proposed" else { return }
        try? TekaStore(folder: folder).reject(proposal, reason: "the file in intake/ changed or is gone", now: now)
    }
}
