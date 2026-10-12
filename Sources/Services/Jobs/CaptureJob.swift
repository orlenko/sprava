import Capture
import Foundation
import SpravaKit

/// The capture watcher (architecture 8; mvp.md feature 4): sweeps the capture root and turns each new capture into
/// a card within the sweep, on the command queue. Counts only in the log.
public enum CaptureJob {
    public static func run(_ context: JobContext, now: Date = Date()) -> JobOutcome {
        guard let commands = context.commands else { return context.noCommands }
        let inbox = commands.inbox
        try? AtomicFile.makePrivateFolder(inbox.root)
        guard let rows = try? context.rows() else { return SentinelJob.shelfUnreadable }
        let result = context.onCommandQueue { inbox.sweep(binders: rows, commands: commands, now: now) }
        if result.ingested + result.quarantined + result.duplicates > 0 || result.refusedFolders > 0 {
            let slowest = result.latencies.max().map { " slowest_s=\(Int($0))" } ?? ""
            context.log("capture ingested=\(result.ingested) filed=\(result.filed) unfiled=\(result.unfiled) duplicates=\(result.duplicates) quarantined=\(result.quarantined) pending=\(result.pending) refused_folders=\(result.refusedFolders)" + slowest)
        }
        if let file = result.unreadable { return .error(code: "capture_state_unreadable", culprit: file) }
        if let file = result.unsaved { return .error(code: "capture_state_unwritable", culprit: file) }
        if result.rootUnlisted { return .error(code: "capture_root_unlisted", culprit: nil) }
        if result.refusedFolders > 0 { return .error(code: "capture_folder_refused", culprit: "\(result.refusedFolders) folder(s)") }
        return .ok   // a sweep that found nothing new still did its work
    }
}
