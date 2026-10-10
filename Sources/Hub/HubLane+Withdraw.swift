import BinderFormat
import BinderStore
import Darwin
import Foundation
import SpravaKit

/// Withdrawing a binder's agenda slice from the spool, and judging whether the slice there shows more than the
/// binder now allows (binder-v0 §8.1, §8.3; architecture 4.5).
extension HubLane {
    /// Removes a slice from the spool. Only a slice that is already gone is fine; any other failure is reported,
    /// so a slice the person withdrew never stays on the hub unnoticed.
    static func removeSlice(_ target: URL) throws {
        guard unlink(target.path) == 0 || errno == ENOENT else {
            throw TekaStore.Refused(reason: "the slice on the spool could not be removed")
        }
    }

    /// The cursors only when they are this binder's own: `.sprava` a real folder and `cursors.json` a regular file
    /// in it, never reached through a link to another binder's.
    static func ownCursors(_ folder: URL) -> Cursors? {
        var info = stat()
        guard lstat(folder.appendingPathComponent(".sprava").path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              lstat(cursorsURL(folder).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? readCursors(folder)
    }

    /// The disclosure the person last confirmed, for a binder whose catalog cannot be read. An op log that cannot
    /// be read fails closed (`none`), as in `PrivacyRatchet.view`.
    static func confirmedDisclosure(_ folder: URL) -> String {
        guard let ops = try? TekaStore(folder: folder).readOpLog().ops else { return "none" }
        return PrivacyRatchet.confirmed(opLog: ops)?.disclosure ?? "full"
    }

    /// Withdraws a binder's slice, whatever else is wrong with the binder. The spool file is never named by the
    /// catalog alone: a binder that passes every check publishes under its own name, which is also its folder's;
    /// one that does not (an outside edit may have renamed it to another binder) withdraws only the slice Sprava
    /// recorded writing for it in its own cursors. So does one whose name collides with another binder's
    /// (`recordedOnly`): the shared name may be the other's slice, so the file goes only while it is still the one
    /// Sprava recorded; one another program wrote there since is left, and no longer this binder's. Returns false
    /// when no slice can be identified that safely.
    /// Every slice the cursors record (`recordedSlices`) counts as Sprava's, once a cut-off publish's pending one is
    /// settled (`reconciled`).
    static func withdraw(_ teka: Teka, inbox: URL, recordedOnly: Bool = false) throws -> Bool {
        let own = ownCursors(teka.folder).map { reconciled($0, folder: teka.folder, inbox: inbox) }
        let byRecord = recordedOnly || teka.federationBlocked
        let recorded = own.map { recordedSlices($0, folder: teka.folder) } ?? []
        // Each name to withdraw, with the hashes that prove a file there is Sprava's; nil removes it whatever it is.
        // Slices recorded under other names go by `removeFormerSlice`.
        var targets: [(name: String, hashes: Set<String>?)] = []
        if !byRecord {
            targets.append((teka.name, nil))
        } else if !recorded.isEmpty {
            for name in Set(recorded.map(\.name)).sorted() {
                targets.append((name, recordedOnly ? Set(recorded.filter { $0.name == name }.map(\.hash)) : nil))
            }
        } else {
            return false
        }
        for (name, hashes) in targets {
            let url = try spoolFile(inbox, name, ".agenda.json")
            if let hashes, let found = sliceOnSpool(at: url), !hashes.contains(found.hash) { continue }
            try removeSlice(url)
        }
        guard var cursors = byRecord ? own : reconciled(try readCursors(teka.folder), folder: teka.folder, inbox: inbox) else {
            return true
        }
        if !byRecord { try removeFormerSlice(cursors, teka: teka, inbox: inbox) }
        cursors.sliceHash = nil
        cursors.sliceName = nil
        cursors.pending = nil
        try saveCursors(cursors, teka.folder)
        return true
    }

    /// The canonical hash of a slice on the spool, `generated` left out; nil when it cannot be read as JSON. Only a
    /// regular file is read, never through a link, so a FIFO there cannot stall the publish.
    static func sliceHash(at url: URL) -> String? { sliceOnSpool(at: url)?.hash }

    /// `sliceHash`, and the slice's `generated` stamp.
    static func sliceOnSpool(at url: URL) -> (hash: String, generated: String?)? {
        guard case .ok(let data) = SafeFile.read(url), let value = try? JSONParser.parse(data).value,
              let hash = try? Canonical.hash(stripGenerated(value)) else { return nil }
        return (hash, value["generated"]?.stringValue)
    }

    /// After a rename each slice Sprava recorded writing under another name goes, before anything is published or
    /// withdrawn under the new one, so its contents never stay on the hub (binder-v0 §8.3). It goes when the name is
    /// one of the binder's unexpired former names or the file is still the one Sprava recorded; a file another
    /// program wrote under a name the binder no longer lists, or lists only past its `until` date, may be another
    /// binder's now, and stays.
    static func removeFormerSlice(_ cursors: Cursors, teka: Teka, inbox: URL, now: Date = Date()) throws {
        let today = CalendarDate.today(now: now)
        let formers = teka.catalog?["meta"]?["former_names"]?.arrayValue ?? []
        for (former, hash, _) in recordedSlices(cursors, folder: teka.folder) where former != teka.name {
            let url = try spoolFile(inbox, former, ".agenda.json")
            let listed = formers.contains { $0["name"]?.stringValue == former && isUnexpired($0, today: today) }
            if listed || sliceHash(at: url) == hash { try removeSlice(url) }
        }
    }

    /// Settles a publish cut off after it recorded its pending slice, before anything else reads or replaces that
    /// record: when the file under the pending name is that slice, its stamp included, it becomes the committed
    /// record with the log position, closures and ids it was built with; otherwise the write never landed (a forced
    /// refresh of the same items differs only in its stamp), or another program replaced it, and the pending record
    /// goes. The committed record it replaces named a slice that publish had already retired or overwritten.
    static func reconciled(_ c: Cursors, folder: URL, inbox: URL) -> Cursors {
        guard let p = c.pending else { return c }
        var out = c
        out.pending = nil
        guard let url = try? spoolFile(inbox, p.name, ".agenda.json"), let found = sliceOnSpool(at: url),
              found.hash == p.hash, p.generated == nil || found.generated == p.generated else { return out }
        out.sliceHash = p.hash
        out.sliceName = p.name
        out.generated = p.generated
        if let n = p.lastLogCount { out.lastLogCount = n }
        if let closed = p.closedOnce { out.closedOnce = closed }
        if let ids = p.published { out.published = ids }
        return out
    }

    /// Withdraws the slice when it shows more than the binder now allows; true when it did.
    static func withdrawIfShowingMore(_ teka: Teka, inbox: URL, nameCollides: Bool) throws -> Bool {
        guard try showsMore(teka, inbox: inbox) else { return false }
        return try withdraw(teka, inbox: inbox, recordedOnly: nameCollides)
    }

    /// Whether the slice Sprava last wrote shows more than the binder allows now, judged against a projection made
    /// without the checks that only publishing needs: an open item that is gone or shown as `done`, a title, party or
    /// link that differs, or a tag no longer shown. An item left in `open_items` with status `done` is judged the
    /// same way (it may stay done); only the rows shown once for closed items, which carry nothing but their id, are
    /// passed over. Every slice the cursors record is judged, a cut-off publish's pending one included. Nothing
    /// recorded, or nothing readable on the spool, shows nothing. A catalog that cannot be read, or whose `open_items` or `processing_log` is not a list, has no items
    /// to judge against: the last slice stays, as for any refused publish (a narrowed disclosure is withdrawn before
    /// this, by `withdrawIfNarrowed`).
    static func showsMore(_ teka: Teka, inbox: URL) throws -> Bool {
        let cursors = reconciled(try readCursors(teka.folder), folder: teka.folder, inbox: inbox)
        let shown: [JSONValue] = try Set(recordedSlices(cursors, folder: teka.folder).map(\.name)).sorted().compactMap { name in
            guard case .ok(let data) = SafeFile.read(try spoolFile(inbox, name, ".agenda.json")) else { return nil }
            return try? JSONParser.parse(data).value
        }
        guard !shown.isEmpty else { return false }
        guard let catalog = teka.catalog else { return false }
        guard let key = try existingSliceKey(teka.folder) else { return true }
        let privacy = PrivacyRatchet.view(folder: teka.folder, catalog: catalog)
        let plan = plan(catalog, folder: teka.folder, cursors: cursors, privacy: privacy)
        guard let allowed = try? projection(catalog: catalog, folderName: teka.folder.lastPathComponent, closedOnce: plan.closedOnce,
                                            key: key, now: Date(), alsoRedact: plan.keepRedacted, keepTitles: privacy.titles,
                                            confirmedTitles: plan.confirmedTitles, lastSeen: cursors.published,
                                            allowTags: plan.allowTags, strict: false) else { return false }
        var open: [String: JSONValue] = [:]
        var any: [String: JSONValue] = [:]
        for it in allowed.slice["items"]?.arrayValue ?? [] {
            guard let id = it["id"]?.stringValue else { continue }
            if any[id] == nil { any[id] = it }
            if it["status"] != .str("done"), open[id] == nil { open[id] = it }
        }
        // A row shown once for an item closed (`project`'s `closedOnce`) carries only the id the hub already saw. Any
        // other row with status `done` is an item an outside edit left in `open_items` as done, published with its
        // title, party, link and tags like an open one, and judged like one.
        let closedIDs = Set(cursors.closedOnce.compactMap { cursors.published[$0] })
        func closure(_ row: JSONValue) -> Bool {
            guard let id = row["id"]?.stringValue, closedIDs.contains(id) else { return false }
            return row["status"] == .str("done") && row["title"] == .str("[closed]") && row["tags"] == .array([])
                && row["waiting_on"] == .null && row["link"] == .null
        }
        for old in shown.flatMap({ $0["items"]?.arrayValue ?? [] }) where !closure(old) {
            let done = old["status"] == .str("done")
            guard let id = old["id"]?.stringValue, let now = done ? any[id] : open[id] else { return true }
            if ["title", "waiting_on", "link"].contains(where: { old[$0] != now[$0] }) { return true }
            let tags = Set(now["tags"]?.arrayValue ?? [])
            if !(old["tags"]?.arrayValue ?? []).allSatisfy(tags.contains) { return true }
        }
        return false
    }
}
