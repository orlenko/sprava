import Darwin
import Foundation
import FoundationModels
import IOKit.pwr_mgt
import Backup
import BinderFormat
import BinderStore
import Brains
import Capture
import Clerk
import Extract
import Hub
import Services
import Shelf
import SpravaKit
import UserNotifications

/// Each job's body. A job runs off the state queue and returns its outcome; counts only in the log.
extension Runtime {
    /// A job that writes, when there are no commands: idle before start, an error when the device id is unreadable.
    var noCommands: JobOutcome {
        queue.sync { deviceIDError } != nil ? .error(code: "device_id_unreadable", culprit: nil) : .skipped
    }

    /// The deadline sentinel: reads every binder on the shelf and records counts per opaque id. Reads only.
    func sentinel() -> JobOutcome {
        let now = Date()
        let today = CalendarDate.today(now: now)
        let rows: [ShelfRow]
        do { rows = try shelfRows() } catch { return Self.shelfUnreadable }
        let idsURL = support.appendingPathComponent("binder-ids.json")
        idsLock.lock()
        guard var ids = try? BinderIDs.load(idsURL) else {
            idsLock.unlock()
            return .error(code: "binder_ids_unreadable", culprit: nil)
        }
        let report = SentinelReport.compute(rows: rows, ids: &ids, today: today, now: now)
        let savedIDs = Result { try ids.save(idsURL) }
        idsLock.unlock()
        do {
            try savedIDs.get()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFile.write(try encoder.encode(report), to: runtimeDir.appendingPathComponent("sentinel.json"))
        } catch {
            return .error(code: "write_failed", culprit: "\(error)")
        }
        queue.async { self.lastSentinelDate = today.description; RuntimeState.update(self.runtimeDir) { $0.lastSentinelDate = today.description } }
        // A binder that cannot be read is a finding, not a failed run; an empty Shelf has nothing to watch yet.
        return rows.isEmpty ? .idle : .ok
    }

    static let shelfUnreadable = JobOutcome.error(code: "shelf_unreadable", culprit: nil)

    /// Settles outside edits in each binder this Mac owns before it is read for others (architecture 4.5), and
    /// trusts the cards that writes, with any held back before (`TrustBacklog`).
    func settleOutsideEdits(_ rows: [ShelfRow], commands: Commands) -> OutsideEdits.Settled {
        let settled = OutsideEdits.settleAndTrust(rows, commands: commands, backlog: trustBacklog) { body in
            onCommandQueue(body)
        }
        if settled.cards > 0 { log("outside_edit undid_changes_cards=\(settled.cards)") }
        if settled.untrusted > 0 { log("trust_failed cards=\(settled.untrusted)") }
        return settled
    }

    /// Runs `body` on the command queue, the single writer of Sprava's record of the cards.
    func onCommandQueue(_ body: () -> Void) {
        if let xpc { xpc.queue.sync(execute: body) } else { body() }
    }

    /// The hub lane (binder-v0 §8; mvp.md feature 7): for each adopted binder this Mac owns, drain the hub's
    /// completions, then publish the slice when it changed. Counts per opaque binder id only.
    func hub() -> JobOutcome {
        guard let commands else { return noCommands }
        let rows: [ShelfRow]
        do { rows = try shelfRows() } catch { return Self.shelfUnreadable }
        // Before anything is published, and also without a spool, so a hand edit becomes an external_edit.
        let settled = settleOutsideEdits(rows, commands: commands)
        let root = HubLane.spoolRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            if settled.untrusted > 0 { return .error(code: "trust_failed", culprit: "\(settled.untrusted) card(s)") }
            return settled.unsettled > 0 ? .error(code: "settle_failed", culprit: "\(settled.unsettled) binder(s)") : .idle
        }
        let mine = rows.filter { $0.teka.isAdopted && Owner.device(of: $0.folder) == commands.deviceID }
        let idsURL = support.appendingPathComponent("binder-ids.json")
        idsLock.lock()
        guard var ids = try? BinderIDs.load(idsURL) else {
            idsLock.unlock()
            return .error(code: "binder_ids_unreadable", culprit: nil)
        }
        let bids = mine.map { ids.id(for: $0.folder) }
        // Ids that cannot be kept would change on the next run: the job still runs and then reports it.
        let idsSaved = (try? ids.save(idsURL)) != nil
        idsLock.unlock()
        var failures: [String] = []
        var untrusted = 0
        // Two known binders under one name would share a spool file: neither publishes nor drains, but a narrowing
        // still withdraws the slice each recorded writing (binder-v0 §3.1; `HubLane.sync`).
        let colliding = HubLane.collidingFolders(rows, today: CalendarDate.today())
        for (row, bid) in zip(mine, bids) {
            let collides = colliding.contains(row.folder.standardizedFileURL.path)
            if collides { log("hub binder=\(bid) name_collision=true") }
            // A drain that fails never holds back the publish, so a narrowing or withdrawal still reaches the hub.
            let synced = HubLane.sync(row.folder, root: root, nameCollides: collides) { drained in
                guard !drained.createdProposals.isEmpty else { return }
                onCommandQueue {
                    do { try trustBacklog.trust(drained.createdProposals, in: row.folder, commands: commands) } catch {
                        untrusted += drained.createdProposals.count
                    }
                }
                log("hub binder=\(bid) overwritten_change_card=1")
            }
            if let drained = synced.drained, drained.applied > 0 || drained.skipped > 0 || drained.waitingForYou > 0 {
                log("hub binder=\(bid) drained=\(drained.applied) skipped=\(drained.skipped) waiting=\(drained.waitingForYou)")
            }
            if case .published(let n, let overwritten)? = synced.published {
                log("hub binder=\(bid) published items=\(n)" + (overwritten ? " overwritten_by_other=true" : ""))
            }
            // A binder that needs attention (a stamped catalog without a valid disclosure, among others) has its slice
            // withdrawn and publishes nothing; the doctor names why. The reason may quote the catalog, so it is not logged.
            if case .removed? = synced.published { log("hub binder=\(bid) slice_withdrawn=true") }
            if case .notPublished? = synced.published { log("hub binder=\(bid) not_published=true") }
            if let error = synced.drainError { log("hub binder=\(bid) drain_error=\(type(of: error))") }
            if let error = synced.publishError { log("hub binder=\(bid) error=\(type(of: error))") }
            if synced.failed { failures.append(bid) }
        }
        // A card left untrusted cannot be approved until a later pass records it: reported first.
        let notTrusted = settled.untrusted + untrusted
        if untrusted > 0 { log("hub trust_failed cards=\(untrusted)") }
        if notTrusted > 0 {
            return .error(code: "trust_failed", culprit: "\(notTrusted) card(s)")
        }
        if settled.unsettled > 0 { failures.append("\(settled.unsettled) unsettled") }
        if !failures.isEmpty { return .error(code: "hub_failed", culprit: "binders " + failures.joined(separator: ",")) }
        return idsSaved ? .ok : .error(code: "binder_ids_unwritable", culprit: nil)
    }

    /// The capture watcher (architecture 8; mvp.md feature 4): sweeps the capture root and turns each new capture
    /// into a Tier 0 card within the sweep. Runs on the command queue, the single writer. Counts only in the log.
    func capture() -> JobOutcome {
        guard let commands, let xpc else { return noCommands }
        let inbox = commands.inbox
        try? AtomicFile.makePrivateFolder(inbox.root)
        guard let rows = try? shelfRows() else { return Self.shelfUnreadable }
        let result = xpc.queue.sync { inbox.sweep(binders: rows, commands: commands) }
        queue.async { self.watchCaptureFolders(inbox.root) }
        let new = result.ingested + result.quarantined + result.duplicates
        if new > 0 || result.refusedFolders > 0 {
            let slowest = result.latencies.max().map { " slowest_s=\(Int($0))" } ?? ""
            log("capture ingested=\(result.ingested) filed=\(result.filed) unfiled=\(result.unfiled) duplicates=\(result.duplicates) quarantined=\(result.quarantined) pending=\(result.pending) refused_folders=\(result.refusedFolders)" + slowest)
        }
        if let file = result.unsaved { log("capture state_unwritable=\(file)") }
        return CaptureJob.outcome(result)
    }

    /// The intake watcher (mvp.md feature 4; adaptation-layer §4): a card for each file that holds still in a
    /// binder's intake/, after the sandboxed helper has read it. Digests and reading happen here, off the command
    /// queue; at most four minutes of reading per run, the rest on the next.
    func intake() -> JobOutcome {
        guard let commands, let xpc else { return noCommands }
        guard let rows = try? shelfRows() else { return Self.shelfUnreadable }
        let watcher = IntakeWatcher(support: support)
        // The sandboxed helper reads every file; without it, each file gets a Held card saying the reader is missing.
        let prepared = watcher.prepare(binders: rows, deviceID: commands.deviceID, reader: .located())
        let result = xpc.queue.sync { watcher.scan(binders: rows, commands: commands, prepared: prepared, requireReading: true) }
        if result.carded > 0 || result.replaced > 0 {
            log("intake carded=\(result.carded) held=\(result.held) replaced=\(result.replaced) waiting=\(result.waiting) stale=\(result.stale)")
        }
        if result.cursorUnreadable { return .error(code: "intake_state_unreadable", culprit: "capture/intake.json") }
        if result.cursorUnsaved { return .error(code: "intake_state_unwritable", culprit: "capture/intake.json") }
        // A binder's intake folder that cannot be listed: its state is left alone and it is counted, never named.
        if result.unreadableFolders > 0 {
            log("intake unreadable_folders=\(result.unreadableFolders)")
            return .error(code: "intake_folder_unreadable", culprit: "\(result.unreadableFolders) binder(s)")
        }
        return .ok
    }

    /// Tier 1 (architecture 5.3): reads the captures whose code-built cards are still untouched, one at a time,
    /// for at most 45 seconds per run. Model calls never hold the command queue. Gated on the author's model
    /// variant for the MVP (mvp.md question 7); `developer.json` `"clerk_any_model": true` lifts the gate.
    func clerk() -> JobOutcome {
        guard let commands, let xpc else { return noCommands }
        let model: AppleClerkModel
        switch AppleClerkModel.load() {
        case .success(let m): model = m
        case .failure: return .skipped
        }
        let anyModel = (try? JSONParser.parse(Data(contentsOf: support.appendingPathComponent("developer.json"))).value["clerk_any_model"]) == .bool(true)
        guard model.contextSize >= 8192 || anyModel else { return .skipped }
        let inbox = commands.inbox
        let started = Date()
        var read = 0
        while Date().timeIntervalSince(started) < 45 {
            guard let work = xpc.queue.sync(execute: { inbox.nextForClerk() }) else { break }
            guard let rows = try? shelfRows() else { return Self.shelfUnreadable }
            let filing = FilingList(support: support).binders(rows: rows, deviceID: commands.deviceID)
            let t0 = Date()
            let interp = blocking { await Clerk(model: model).read(work.event, filing: filing, hint: work.hint) }
            let seconds = Date().timeIntervalSince(t0)
            let outcome = xpc.queue.sync { inbox.commitClerk(work, interp, filing: filing, rows: rows, commands: commands, seconds: seconds) }
            log("clerk outcome=\(interp.outcome) items=\(outcome.items) filed=\(outcome.filed) not_sure=\(outcome.unsure) calls=\(interp.calls) ms=\(Int(seconds * 1000))")
            read += 1
        }
        // Then intake documents (adaptation-layer §4.2, §4.3), one at a time, started within the same 45 seconds.
        let watcher = IntakeWatcher(support: support)
        while Date().timeIntervalSince(started) < 45 {
            guard let entry = xpc.queue.sync(execute: { watcher.nextForReading() }) else { break }
            let folder = URL(fileURLWithPath: entry.binder, isDirectory: true)
            guard let rows = try? shelfRows() else { return Self.shelfUnreadable }
            // A binder whose label cannot be made (its key is unreadable) is never named: the document is read
            // without a binder, as FilingList.binders leaves it out.
            let list = FilingList(support: support)
            let binder = list.binders(rows: rows, deviceID: commands.deviceID).first { $0.folder.standardizedFileURL.path == entry.binder }
                ?? rows.first { $0.folder.standardizedFileURL.path == entry.binder }.flatMap { row in
                    (try? list.name(of: row)).map { name in
                        FilingBinder(name: name, description: "", folder: folder, openItems: FilingBinder.candidates(catalog: row.teka.catalog))
                    }
                }
            let t0 = Date()
            let locale = IntakeReading.language(of: entry.reading.text)
            let doc = blocking { await Clerk(model: model).readDocument(entry.reading, name: entry.name, binder: binder, locale: locale) }
            let seconds = Date().timeIntervalSince(t0)
            if doc.title == nil && doc.summary == nil && doc.items.isEmpty {
                xpc.queue.sync { watcher.failReading(entry) }
                log("clerk document outcome=failed calls=\(doc.calls) ms=\(Int(seconds * 1000))")
            } else {
                let outcome = xpc.queue.sync { watcher.commitReading(entry, doc, commands: commands) }
                log("clerk document outcome=\(doc.outcome) class=\(doc.documentClass) items=\(outcome.items) escalated=\(outcome.escalated) card_changed=\(outcome.cardChanged) calls=\(doc.calls) ms=\(Int(seconds * 1000))")
            }
            read += 1
        }
        if read > 0 { queue.async { self.model?.last_success = ISOTime.string(Date()) } }
        return .ok
    }

    /// Keeps each switched DASHBOARD.md current (binder-v0 §7.1): on a catalog change and once a day.
    func dashboards() -> JobOutcome {
        guard let commands else { return noCommands }
        guard let rows = try? shelfRows() else { return Self.shelfUnreadable }
        // A hand edit is absorbed before the dashboard is rendered from the catalog (the first run is at start).
        let settled = settleOutsideEdits(rows, commands: commands)
        let today = CalendarDate.today()
        // Each binder on its own: one whose dashboard record cannot be read fails the job, never the other binders.
        let r = DashboardJob.run(rows, deviceID: commands.deviceID) { folder in
            try DashboardKeeper(folder: folder, impl: commands.client).refresh(today: today)
        }
        let failed = r.failed + settled.unsettled
        if r.rendered > 0 || failed > 0 {
            log("dashboard rendered=\(r.rendered) edited_outside_notes=\(r.editedOutsideNotes) failed=\(failed) unreadable=\(r.unreadable)")
        }
        if r.editedOutsideNotes > 0 {
            notify(title: "Sprava", body: "A DASHBOARD.md was edited outside its Notes section. The edited copy was saved in the binder's .sprava folder.",
                   id: "dashboard-edited")
        }
        return DashboardJob.outcome(r, settled: settled)
    }

    /// Backup (docs/backup.md): first one request the app queued (offload, restore, drill, back up now), then the
    /// scheduled work, which itself does nothing until something is due. The scheduled work runs after a request
    /// too, so an offload left waiting for iCloud never holds up the other binders' backups and checks.
    func backup() -> JobOutcome {
        guard let commands else { return noCommands }
        let backup = Backup(support: support)
        // Not set up is a skip; settings that cannot be read, or a missing key, are failures Health shows.
        if let outcome = BackupJob.readiness(backup) {
            if case .error(let code, _) = outcome { log("backup \(code.replacingOccurrences(of: "backup_", with: ""))") }
            return outcome
        }
        let requests = BackupRequests(support: support)
        var requestOutcome = JobOutcome.ok
        do {
            if let request = try requests.next() {
                do { try requests.run(request, backup: backup, deviceID: commands.deviceID) } catch {
                    // The queue could not record the request as running, or how it ended: reported, never "done".
                    log("backup request=\(request.kind) queue_unwritable")
                    requestOutcome = .error(code: "backup_requests_unwritable", culprit: request.kind)
                }
                let state = (try? requests.all())?.first { $0.id == request.id }?.state ?? "?"
                log("backup request=\(request.kind) state=\(state)")
                if state == "done" { notify(title: "Sprava", body: "Backup: \(request.kind.replacingOccurrences(of: "_", with: " ")) finished.", id: "backup-\(request.id)") }
                if state == "failed", requestOutcome == .ok { requestOutcome = .error(code: "backup_request_failed", culprit: request.kind) }
            }
        } catch {
            // A queue that cannot be read is left as it is, and reported; the scheduled work still runs.
            log("backup requests_unreadable")
            requestOutcome = .error(code: "backup_requests_unreadable", culprit: nil)
        }
        guard let rows = try? shelfRows() else { return Self.shelfUnreadable }
        let m = backup.maintain(rows: rows, deviceID: commands.deviceID)
        if m.snapshots > 0 || m.failed > 0 || m.retention || m.checked {
            log("backup snapshots=\(m.snapshots) unchanged=\(m.unchanged) failed=\(m.failed) failed_parts=\(m.failedParts.joined(separator: ",")) shared_backup_ids=\(m.sharedBackupIDs.count) state=\(m.stateSnapshot) retention=\(m.retention) checked=\(m.checked)")
        }
        return BackupJob.outcome(failed: m.failed, failedParts: m.failedParts, sharedBackupIDs: m.sharedBackupIDs.count, requests: requestOutcome)
    }

    /// The Shelf for a job: one that cannot be read fails the job, never reads as an empty Shelf.
    func shelfRows() throws -> [ShelfRow] {
        try ShelfStore(supportDirectory: support).rowsForJobs()
    }

    /// The daily summary: one notification with counts only, at most once per calendar day.
    func summary() -> JobOutcome {
        let today = CalendarDate.today().description
        if queue.sync(execute: { lastSummaryDate }) == today { return .skipped }
        let reportURL = runtimeDir.appendingPathComponent("sentinel.json")
        func current() -> SentinelReport? {
            guard let data = try? Data(contentsOf: reportURL),
                  let report = try? JSONDecoder().decode(SentinelReport.self, from: data), report.date == today else { return nil }
            return report
        }
        // The sentinel may not have run yet today (a start just after midnight, or the first run): compute it now,
        // unless its breaker is open, which this call must not get around.
        let breaker = queue.sync { records.jobs["sentinel"]?.breaker }
        switch SummaryFallback.decide(reportFresh: current() != nil, sentinelBreaker: breaker) {
        case .useReport: break
        case .runSentinel: _ = sentinel()
        case .stale: return .error(code: "sentinel_stale", culprit: "sentinel breaker open")
        }
        guard let report = current() else { return .error(code: "sentinel_stale", culprit: nil) }
        if let text = report.summaryText {
            // Outside the app bundle there is no notification identity: a development run skips, never fails.
            if Bundle.main.bundleURL.pathExtension != "app" { return .skipped }
            guard notify(title: "Sprava today", body: text, id: "summary-\(today)") else {
                return .error(code: "notification_failed", culprit: nil)
            }
        }
        queue.async { self.lastSummaryDate = today; RuntimeState.update(self.runtimeDir) { $0.lastSummaryDate = today } }
        return .ok
    }

    func checkAlerts() -> JobOutcome {
        let authorized = Notifier.authorized()
        let model = ModelStatus.read()
        queue.async {
            self.alerts = Heartbeat.Alerts(authorized: authorized ?? false, checked_at: ISOTime.string(Date()))
            var m = model
            m.last_success = self.model?.last_success   // the clerk's last reading survives the hourly check
            self.model = m
        }
        // Outside the app bundle (a development run) there is no notification identity: recorded as skipped,
        // and the heartbeat shows alerts as off.
        return authorized == nil ? .skipped : .ok
    }

    @discardableResult
    func notify(title: String, body: String, id: String) -> Bool {
        let ok = Notifier.post(title: title, body: body, id: id)
        if !ok { log("notification_failed id=\(id.prefix(32))") }
        return ok
    }
}
