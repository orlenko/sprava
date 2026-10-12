import Capture
import Extract
import Foundation

/// The intake watcher (mvp.md feature 4; adaptation-layer §4): a card for each file that holds still in a binder's
/// intake/, after the sandboxed helper has read it. Digests and reading happen off the command queue; the cards on it.
public enum IntakeJob {
    public static func run(_ context: JobContext, reader: ExtractHelper.Reader = .located(), now: Date = Date()) -> JobOutcome {
        guard let commands = context.commands else { return context.noCommands }
        guard let rows = try? context.rows() else { return SentinelJob.shelfUnreadable }
        let watcher = IntakeWatcher(support: context.support)
        // Without the helper, each file gets a held card saying the reader is missing.
        let prepared = watcher.prepare(binders: rows, deviceID: commands.deviceID, reader: reader)
        let result = context.onCommandQueue {
            watcher.scan(binders: rows, commands: commands, now: now, prepared: prepared, requireReading: true)
        }
        if result.carded > 0 || result.replaced > 0 {
            context.log("intake carded=\(result.carded) held=\(result.held) replaced=\(result.replaced) waiting=\(result.waiting) stale=\(result.stale)")
        }
        if result.cursorUnreadable { return .error(code: "intake_state_unreadable", culprit: "capture/intake.json") }
        if result.cursorUnsaved { return .error(code: "intake_state_unwritable", culprit: "capture/intake.json") }
        // A binder's intake folder that cannot be listed is counted, never named.
        if result.unreadableFolders > 0 {
            context.log("intake unreadable_folders=\(result.unreadableFolders)")
            return .error(code: "intake_folder_unreadable", culprit: "\(result.unreadableFolders) binder(s)")
        }
        return .ok
    }
}
