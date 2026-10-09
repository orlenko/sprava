import BinderFormat
import BinderStore
import Clerk
import Darwin
import Extract
import Foundation
import Shelf
import SpravaKit

/// The intake watcher (mvp.md feature 4; docs/adaptation-layer.md §4): each adopted binder's `intake/` folder,
/// top level, plus the messages a mail monitor writes to `intake/mail/`. A file that holds still between two scans
/// is read in the sandboxed helper (off the command queue, by `prepare`) and becomes a Tier 0 card proposing
/// `file_document`, with what code found in it; the clerk's document reading may then replace the card.
public struct IntakeWatcher: Sendable {
    public let support: URL

    public init(support: URL) { self.support = support }

    package var stateURL: URL { support.appendingPathComponent("capture/intake.json") }

    package struct Seen: Codable, Equatable {
        var size: Int
        var mtime: Double
        package var card: String?
        var firstSeen: Date
        /// The file has a card but its reading could not be written: `prepare` reads it again and `scan` keeps
        /// the reading then, so the document still reaches the clerk (adaptation-layer §4.2).
        package var readingMissing: Bool?
    }

    /// The cursor: empty only when `intake.json` does not exist. One that cannot be read or decoded throws, so it is
    /// never saved over: rebuilt, it would card again every file the person already rejected (capture-event-v0 §5.3).
    package func load() throws -> [String: [String: Seen]] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try StateFile.read([String: [String: Seen]].self, from: stateURL, decoder: decoder) ?? [:]
    }

    package func save(_ s: [String: [String: Seen]]) throws {
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
        /// Key or credential files in some intake/ with nothing else to file: never carded, never read; shown on
        /// Health so the person can move them out.
        public var heldWithoutCard = 0
        /// Files that sat in some intake/ for more than 7 days without being filed (mvp.md 1.2, currency).
        public var stale = 0
        /// The cursor could not be written: every file would look new on every scan, so the job reports it.
        public var cursorUnsaved = false
        /// The cursor exists but cannot be read: nothing was scanned, and nothing was written over it.
        public var cursorUnreadable = false
        /// Intake folders that exist but could not be listed: their cards and their cursor were kept as they are.
        public var unreadableFolders = 0

        package init() {}
    }

    /// One thing in `intake/` worth a card: a file, or a message with the files of its attachments folder.
    public struct Candidate: Sendable, Equatable {
        public var name: String              // relative to intake/
        public var size: Int                 // all its files together
        public var mtime: Double             // the latest of them
        public var attachments: [String] = []   // relative to intake/
        public var channel = "other"
    }

    /// A file's digest for the cursor and its card: its SHA-256, except for a key or credential file, which is never
    /// opened (binder-v0 §3.3) and is known by its size and modification time instead. Nil when it cannot be read.
    static func digest(of url: URL) -> String? {
        guard DocumentPaths.isKeyFile(url.lastPathComponent) else { return DocumentPaths.sha256(of: url) }
        return plainFile(url).map { "unread:\($0.size):\($0.mtime)" }
    }

    static func plainFile(_ url: URL) -> (size: Int, mtime: Double)? {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid() else { return nil }
        return (Int(s.st_size), Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Whether anything is at `url` (a link, a file, a folder), seen without following it.
    static func exists(_ url: URL) -> Bool {
        var s = stat()
        return lstat(url.path, &s) == 0 || errno != ENOENT
    }

    static func folderTime(_ url: URL) -> Double? {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid() else { return nil }
        return Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9
    }

    /// The files of `intake/` worth a card: plain files of this user, not dot names, not `_converted/`; and in
    /// `mail/`, each message (`.md` from a mail monitor, or `.eml`) with its `<name> attachments/` folder.
    /// A mail monitor's `.env` and `state.json` are never read (binder-v0 §3.3). Empty when any folder cannot be listed.
    public static func candidates(in folder: URL) -> [Candidate] { (try? listCandidates(in: folder)) ?? [] }

    /// A folder of intake that exists but cannot be listed: not an empty one.
    struct UnlistedFolder: Error { let path: String }

    /// The contents of a folder that exists, or a throw when it cannot be listed.
    static func contents(_ url: URL) throws -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: url.path) } catch { throw UnlistedFolder(path: url.path) }
    }

    /// `candidates`, or a throw when `intake/`, `intake/mail/` or an attachments folder exists but cannot be listed, so
    /// a folder briefly out of reach never reads as one whose files all went.
    static func listCandidates(in folder: URL) throws -> [Candidate] {
        let intake = folder.appendingPathComponent("intake")
        // Only a folder that is not there is empty: one there but not a plain folder of this user is out of reach.
        guard folderTime(intake) != nil else { if exists(intake) { throw UnlistedFolder(path: intake.path) }; return [] }
        let names = try contents(intake)
        var out: [Candidate] = names.sorted().compactMap { name in
            guard !name.hasPrefix("."), !["_converted", "mail"].contains(name), DocumentPaths.isIntake("intake/" + name),
                  let f = plainFile(intake.appendingPathComponent(name)) else { return nil }
            return Candidate(name: name, size: f.size, mtime: f.mtime)
        }
        let mail = intake.appendingPathComponent("mail")
        guard folderTime(mail) != nil else { if exists(mail) { throw UnlistedFolder(path: mail.path) }; return out }
        let messages = try contents(mail)
        for name in messages.sorted() {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["md", "eml"].contains(ext), !name.hasPrefix("."), DocumentPaths.isIntake("intake/mail/" + name),
                  let f = plainFile(mail.appendingPathComponent(name)) else { continue }
            var c = Candidate(name: "mail/" + name, size: f.size, mtime: f.mtime, channel: "email")
            let stem = (name as NSString).deletingPathExtension
            for folderName in [stem + " attachments", name + " attachments"] {
                let dir = mail.appendingPathComponent(folderName)
                guard let t = folderTime(dir) else { continue }
                let files = try contents(dir)
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

    /// Reads the files the next scan would card: they held still since the last scan and have no card yet, or
    /// their card's reading could not be kept (read again once per call). At most `budget` seconds of reading per
    /// call; the rest wait for the next one. The runtime passes the located
    /// helper; a missing one holds each file with a card that says so.
    public func prepare(binders: [ShelfRow], deviceID: String, reader: ExtractHelper.Reader, read: Bool = true,
                        budget: TimeInterval = 240) -> Prepared {
        // A cursor that cannot be read names no file as held still: nothing is read (scan reports it).
        guard let state = try? load() else { return Prepared() }
        let started = Date()
        var out = Prepared()
        for row in binders where row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == deviceID {
            let seen = state[row.folder.standardizedFileURL.path] ?? [:]
            for c in (try? Self.listCandidates(in: row.folder)) ?? [] {
                guard let e = seen[c.name], e.card == nil || e.readingMissing == true, e.size == c.size, e.mtime == c.mtime else { continue }
                if read && Date().timeIntervalSince(started) > budget { return out }
                let file = row.folder.appendingPathComponent("intake/" + c.name)
                let attachments = c.attachments.map { row.folder.appendingPathComponent("intake/" + $0) }
                for url in [file] + attachments { out.digests[url.path] = Self.digest(of: url) }
                if read { out.readings[file.path] = IntakeReading.read(file, in: row.folder, attachments: attachments, channel: c.channel, reader: reader) }
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
            // An intake folder that cannot be listed is not an empty one: its cards and its cursor stay as they are.
            guard let files = try? Self.listCandidates(in: row.folder) else {
                result.unreadableFolders += 1
                continue
            }
            // Nor is a binder whose cards cannot all be read one without cards: a file's card missed now would be made
            // twice, and a stranded one never withdrawn.
            guard CaptureInbox.cardsReadable(in: ProposalStore.dir(row.folder)) else {
                result.unreadableFolders += 1
                continue
            }
            // Cards already waiting for a file, matched by name and digest, are never made twice.
            var waiting = ProposalStore.list(in: row.folder).map(\.0).filter { $0.state == "proposed" && $0.raw["provenance"]?["intake"] != nil }
            for file in files {
                var entry = seen.removeValue(forKey: file.name)
                if let e = entry, e.size == file.size, e.mtime == file.mtime {
                    if e.card == nil {
                        // Nothing here may ever be filed (only key or credential files, binder-v0 §3.3): a card would
                        // have no change to approve, so none is made; Health counts the file as held.
                        if ([file.name] + file.attachments).allSatisfy(DocumentPaths.isKeyFile) {
                            result.heldWithoutCard += 1
                            next[file.name] = entry
                            continue
                        }
                        let path = row.folder.appendingPathComponent("intake/" + file.name).path
                        let reading = prepared.readings[path]
                        if requireReading && reading == nil { result.waiting += 1; next[file.name] = entry; continue }
                        let sha = prepared.digests[path] ?? Self.digest(of: URL(fileURLWithPath: path))
                        let matching = waiting.filter { $0.raw["provenance"]?["intake"]?["name"]?.stringValue == file.name
                            && $0.raw["provenance"]?["intake"]?["sha256"]?.stringValue == sha }
                        // Only a card Sprava recorded is taken over, with its reading made sure of, and only when it files
                        // exactly the files there now: the message and every attachment, each by its digest (one that
                        // changed, or was added or removed, makes it stale). One it cannot vouch for could never be
                        // approved, so it is withdrawn and the file carded again.
                        if let existing = matching.first(where: {
                            commands.isTrusted($0.id, in: row.folder) && Self.filesSame($0, file: file, sha: sha, digests: prepared.digests, in: row.folder)
                        }) {
                            entry?.card = existing.id
                            if let sha, IntakeReadings(support: support).forCard(existing.id) == nil {
                                entry?.readingMissing = saveReading(reading, file: file, sha: sha, card: existing.id, in: row, now: now) ? nil : true
                            }
                        } else {
                            // A stale card that cannot be withdrawn now is never left beside a new one: the file waits.
                            let cleared = matching.map { withdraw($0.id, in: row.folder, deviceID: commands.deviceID, now: now) }
                            guard !cleared.contains(false) else { next[file.name] = entry; continue }
                            entry?.card = card(file, sha: sha, reading: reading, digests: prepared.digests, in: row, commands: commands, now: now)
                            if let made = entry?.card, let sha {
                                result.carded += 1
                                if reading?.held != nil { result.held += 1 }
                                // The card stands even when its reading cannot be written: the person can still file
                                // the document. The reading is tried again from the next `prepare`.
                                entry?.readingMissing = saveReading(reading, file: file, sha: sha, card: made, in: row, now: now) ? nil : true
                            }
                        }
                    } else {
                        if let card = e.card { entry?.card = finishReplacement(card, waiting: &waiting, in: row.folder, deviceID: commands.deviceID, now: now) }
                        if e.readingMissing == true, let card = e.card {
                            entry?.readingMissing = retryReading(prepared, file: file, card: card, in: row, commands: commands, now: now) ? nil : true
                        }
                        if now.timeIntervalSince(e.firstSeen) > 7 * 86_400 { result.stale += 1 }
                    }
                } else {
                    // New, or still being written, or changed after its card: wait for it to hold still. A card for
                    // the old bytes is withdrawn; its digest would be refused on approval anyway.
                    if let old = entry?.card {
                        // Until its old card is withdrawn, the entry keeps following it (and tries again next scan).
                        guard withdraw(old, in: row.folder, deviceID: commands.deviceID, now: now) else { next[file.name] = entry; continue }
                        result.replaced += 1
                    }
                    entry = Seen(size: file.size, mtime: file.mtime, card: nil, firstSeen: entry?.firstSeen ?? now)
                    result.waiting += 1
                }
                next[file.name] = entry
            }
            // Files gone from intake/ (filed, or removed by the person): cards still waiting for them are withdrawn.
            // One whose card cannot be withdrawn now stays in the cursor, so the next scan tries again.
            for (name, gone) in seen {
                if let card = gone.card, !withdraw(card, in: row.folder, deviceID: commands.deviceID, now: now) { next[name] = gone }
            }
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
    package static func freePath(_ folder: String, _ name: String, in binder: URL) -> String {
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

    /// Whether what came in on `channel` is private by default. Everything that reaches a binder's intake is other
    /// people's material: documents, scans and email (adaptation-layer §2.8; capture-event-v0 §9), so every channel
    /// is. A note the person wrote comes as a capture event, never through intake. The person may mark a filed
    /// document or item otherwise on its card; the op log records that.
    static func isPrivate(channel: String) -> Bool { true }

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
        // A key or credential file is never filed (binder-v0 §3.3): the card holds it, it never moves it, so the card
        // stays one the person can approve.
        for (index, name) in ([file.name] + file.attachments).enumerated() where !DocumentPaths.isKeyFile(name) {
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
            // Other people's material is private by default (adaptation-layer §2.8; capture-event-v0 §3.3): the filed
            // copy is recorded redacted, and the person may change that on the card.
            if Self.isPrivate(channel: reading?.channel ?? file.channel) { document.set("redact", .bool(true)) }
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
        var provenance = JSONObject([(key: "intake", value: .object(intake)), (key: "filed_by", value: .str("code, no model"))])
        if Self.isPrivate(channel: reading?.channel ?? file.channel) { provenance.set("private", .bool(true)) }
        let shown = Self.title(file.name, subject: reading?.subject)
        let title: String
        if reading?.held != nil { title = "Held: \u{201C}\(shown)\u{201D} was not read" }
        else if isMail { title = "File the email \u{201C}\(shown)\u{201D}" + (file.attachments.isEmpty ? "" : " and \(file.attachments.count) attachment(s)") }
        else { title = "File \u{201C}\(DocumentPaths.safeName(file.name))\u{201D} from intake" }
        let proposal = Proposal.make(title: title, actor: actor, ops: ops, provenance: provenance, now: now)
        do {
            try BinderWrite.save(proposal, in: row.folder, deviceID: commands.deviceID)
        } catch {
            return nil
        }
        do {
            try commands.trustProposals([proposal.id], in: row.folder)
        } catch {
            // A card whose digest was not kept could never be approved: it goes, and the file stays uncarded, so the
            // next scan cards it again.
            BinderWrite.takeBackUntrusted(proposal, in: row.folder, deviceID: commands.deviceID, now: now)
            return nil
        }
        return proposal.id
    }

    /// A reading with text waits for the clerk's document reading (§4.2, §4.3). Returns false when it had to be
    /// kept and could not be written.
    func saveReading(_ reading: IntakeReading?, file: Candidate, sha: String, card: String, in row: ShelfRow, now: Date) -> Bool {
        guard let r = reading, r.held == nil, !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let entry = IntakeReadings.Entry(id: UUIDv7.make(now: now), binder: row.folder.standardizedFileURL.path, name: file.name,
                                         sha256: sha, card: card, reading: r, now: now)
        return (try? IntakeReadings(support: support).save(entry)) != nil
    }

    /// Keeps the reading of a carded file whose reading could not be written before, from what `prepare` read
    /// this time. Returns true once nothing is missing any more: the reading is kept, or its card no longer waits
    /// for the person or is not the one Sprava wrote, so nothing would follow from a reading.
    func retryReading(_ prepared: Prepared, file: Candidate, card: String, in row: ShelfRow, commands: Commands, now: Date) -> Bool {
        guard let p = try? commands.loadTrusted(card, in: row.folder), p.state == "proposed" else { return true }
        if IntakeReadings(support: support).forCard(card) != nil { return true }
        let path = row.folder.appendingPathComponent("intake/" + file.name).path
        // The bytes read now must be the ones the card files.
        guard let reading = prepared.readings[path], let sha = prepared.digests[path],
              sha == p.raw["provenance"]?["intake"]?["sha256"]?.stringValue else { return false }
        return saveReading(reading, file: file, sha: sha, card: card, in: row, now: now)
    }

    /// Finishes a replacement of a file's card by the clerk's reading that a crash cut short (`commitReading`): a
    /// clerk's card whose reading names it takes over from the card it replaces, and a card it replaces that still
    /// waits is withdrawn. Returns the card the cursor follows now.
    /// Whether a filing card files exactly `file`'s source files as they are now: each `intake/` path once, with the
    /// digest it has now. A file whose digest cannot be taken matches nothing.
    static func filesSame(_ card: Proposal, file: Candidate, sha: String?, digests: [String: String], in folder: URL) -> Bool {
        var expected: [String: String] = [:]
        for (index, name) in ([file.name] + file.attachments).enumerated() where !DocumentPaths.isKeyFile(name) {
            let url = folder.appendingPathComponent("intake/" + name)
            guard let digest = index == 0 ? sha : (digests[url.path] ?? DocumentPaths.sha256(of: url)) else { return false }
            expected["intake/" + name] = digest
        }
        var filed: [String: String] = [:]
        for op in card.ops where op["op"] == .str("file_document") {
            guard let from = op["args"]?["from"]?.stringValue, let digest = op["args"]?["document"]?["sha256"]?.stringValue,
                  filed[from] == nil else { return false }
            filed[from] = digest
        }
        return filed == expected
    }

    func finishReplacement(_ card: String, waiting: inout [Proposal], in folder: URL, deviceID: String, now: Date) -> String {
        var followed = card
        let readings = IntakeReadings(support: support)
        if let next = waiting.first(where: { $0.raw["provenance"]?["replaces"] == .string(card) }), readings.forCard(next.id)?.state == "read" {
            followed = next.id
        }
        guard let mine = waiting.first(where: { $0.id == followed }), let old = mine.raw["provenance"]?["replaces"]?.stringValue,
              waiting.contains(where: { $0.id == old }) else { return followed }
        // Left waiting when it cannot be withdrawn now: the next scan follows the same link and tries again.
        if withdraw(old, in: folder, deviceID: deviceID, now: now) { waiting.removeAll { $0.id == old } }
        return followed
    }

    /// Withdraws the card of an intake file that changed or went. True once it no longer waits; false when it could
    /// not be withdrawn now (the binder cannot be written), so the cursor keeps following it and tries again. Its
    /// reading, the clerk's included, goes with it, and a careful reading it asked for is no longer waited for; a card
    /// the person approved keeps both.
    @discardableResult
    func withdraw(_ id: String, in folder: URL, deviceID: String, now: Date) -> Bool {
        if let (proposal, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == id }), proposal.state == "proposed" {
            guard (try? BinderWrite.reject(proposal, in: folder, reason: "the file in intake/ changed or is gone", deviceID: deviceID, now: now)) != nil else {
                return false
            }
        }
        // A card the person approved filed the document: its reading, and a careful reading it asked for, still stand
        // (the brain's queue takes applied cards). Only a card withdrawn or rejected retires them.
        if ProposalStore.list(in: folder).first(where: { $0.0.id == id })?.0.state == "applied" { return true }
        let readings = IntakeReadings(support: support)
        if var e = readings.forCard(id), e.state != "gone" {
            e.state = "gone"
            if e.escalation == "waiting" { e.escalation = nil }
            // Not saved, the reading would be kept (and its words with it) for a card that is gone: tried again.
            guard (try? readings.save(e)) != nil else { return false }
        }
        return true
    }
}
