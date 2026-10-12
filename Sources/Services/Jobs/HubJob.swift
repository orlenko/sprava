import BinderFormat
import BinderStore
import Foundation
import Hub
import Shelf
import SpravaKit

/// The hub lane (binder-v0 §8; mvp.md feature 7): for each adopted binder this Mac owns, drain the hub's
/// completions, then publish the slice when it changed. Outside edits are settled first, also without a spool, so a
/// hand edit becomes an `external_edit`. Counts per opaque binder id only.
public enum HubJob {
    public static func run(_ context: JobContext, root: URL = HubLane.spoolRoot(), today: CalendarDate = .today(),
                           now: Date = Date()) -> JobOutcome {
        guard let commands = context.commands else { return context.noCommands }
        let rows: [ShelfRow]
        do { rows = try context.rows() } catch { return SentinelJob.shelfUnreadable }
        let settled = context.settleOutsideEdits(rows, commands: commands)
        guard FileManager.default.fileExists(atPath: root.path) else {
            if settled.untrusted > 0 { return .error(code: "trust_failed", culprit: "\(settled.untrusted) card(s)") }
            return settled.unsettled > 0 ? .error(code: "settle_failed", culprit: "\(settled.unsettled) binder(s)") : .idle
        }
        let mine = rows.filter { $0.teka.isAdopted && Owner.device(of: $0.folder) == commands.deviceID }
        let idsURL = context.support.appendingPathComponent("binder-ids.json")
        context.idsLock.lock()
        guard var ids = try? BinderIDs.load(idsURL) else {
            context.idsLock.unlock()
            return .error(code: "binder_ids_unreadable", culprit: nil)
        }
        let bids = mine.map { ids.id(for: $0.folder) }
        // Ids that cannot be kept would change on the next run: the job still runs and then reports it.
        let idsSaved = (try? ids.save(idsURL)) != nil
        context.idsLock.unlock()
        var failures: [String] = []
        var untrusted = 0
        // Two known binders under one name would share a spool file: neither publishes nor drains, but a narrowing
        // still withdraws the slice each recorded writing (binder-v0 §3.1; `HubLane.sync`).
        let colliding = HubLane.collidingFolders(rows, today: today)
        for (row, bid) in zip(mine, bids) {
            let collides = colliding.contains(row.folder.standardizedFileURL.path)
            if collides { context.log("hub binder=\(bid) name_collision=true") }
            // A drain that fails never holds back the publish, so a narrowing or withdrawal still reaches the hub.
            let synced = HubLane.sync(row.folder, root: root, now: now, nameCollides: collides) { drained in
                guard !drained.createdProposals.isEmpty else { return }
                context.onCommandQueue {
                    do { try context.trustBacklog.trust(drained.createdProposals, in: row.folder, commands: commands) } catch {
                        untrusted += drained.createdProposals.count
                    }
                }
                context.log("hub binder=\(bid) overwritten_change_card=1")
            }
            if let drained = synced.drained, drained.applied > 0 || drained.skipped > 0 || drained.waitingForYou > 0 {
                context.log("hub binder=\(bid) drained=\(drained.applied) skipped=\(drained.skipped) waiting=\(drained.waitingForYou)")
            }
            if case .published(let n, let overwritten)? = synced.published {
                context.log("hub binder=\(bid) published items=\(n)" + (overwritten ? " overwritten_by_other=true" : ""))
            }
            if let error = synced.drainError { context.log("hub binder=\(bid) drain_error=\(type(of: error))") }
            if let error = synced.publishError { context.log("hub binder=\(bid) error=\(type(of: error))") }
            if synced.failed { failures.append(bid) }
        }
        // A card left untrusted cannot be approved until a later pass records it: reported first.
        let notTrusted = settled.untrusted + untrusted
        if untrusted > 0 { context.log("hub trust_failed cards=\(untrusted)") }
        if notTrusted > 0 { return .error(code: "trust_failed", culprit: "\(notTrusted) card(s)") }
        if settled.unsettled > 0 { failures.append("\(settled.unsettled) unsettled") }
        if !failures.isEmpty { return .error(code: "hub_failed", culprit: "binders " + failures.joined(separator: ",")) }
        return idsSaved ? .ok : .error(code: "binder_ids_unwritable", culprit: nil)
    }
}
