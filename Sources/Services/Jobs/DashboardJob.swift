import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

/// The dashboard job's pass over the Shelf (binder-v0 §7.1): each switched DASHBOARD.md this Mac owns is refreshed
/// on its own, so one binder that fails never stops the others. Counts only.
public enum DashboardJob {
    public struct Result: Sendable, Equatable {
        public var rendered = 0
        public var editedOutsideNotes = 0
        public var failed = 0
        /// Failures because Sprava's record of a dashboard could not be read (`StateFile.Unreadable`).
        public var unreadable = 0

        public init() {}
    }

    /// `refresh` is `DashboardKeeper.refresh` for one folder (tests pass their own).
    public static func run(_ rows: [ShelfRow], deviceID: String,
                           refresh: (URL) throws -> DashboardKeeper.Refresh) -> Result {
        var out = Result()
        for row in rows where row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == deviceID {
            do {
                if case .rendered(let edited) = try refresh(row.folder) {
                    out.rendered += 1
                    if edited { out.editedOutsideNotes += 1 }
                }
            } catch is StateFile.Unreadable {
                out.failed += 1
                out.unreadable += 1
            } catch {
                out.failed += 1
            }
        }
        return out
    }

    /// The job's outcome: a record that cannot be read first, then cards left untrusted, then any other failure.
    public static func outcome(_ result: Result, settled: OutsideEdits.Settled) -> JobOutcome {
        if result.unreadable > 0 { return .error(code: "dashboard_state_unreadable", culprit: "\(result.unreadable) binder(s)") }
        if settled.untrusted > 0 { return .error(code: "trust_failed", culprit: "\(settled.untrusted) card(s)") }
        let failed = result.failed + settled.unsettled
        return failed > 0 ? .error(code: "dashboard_failed", culprit: "\(failed) binder(s)") : .ok
    }

    /// Keeps each switched DASHBOARD.md current (binder-v0 §7.1): on a catalog change and once a day. A hand edit is
    /// absorbed before the dashboard is rendered from the catalog. `notify` tells the person when a dashboard was
    /// edited outside its Notes section.
    public static func run(_ context: JobContext, today: CalendarDate = .today(), now: Date = Date(),
                           notify: (_ title: String, _ body: String, _ id: String) -> Void) -> JobOutcome {
        guard let commands = context.commands else { return context.noCommands }
        guard let rows = try? context.rows() else { return SentinelJob.shelfUnreadable }
        let settled = context.settleOutsideEdits(rows, commands: commands)
        // Each binder on its own: one whose dashboard record cannot be read fails the job, never the other binders.
        let r = run(rows, deviceID: commands.deviceID) { folder in
            try DashboardKeeper(folder: folder, impl: commands.client).refresh(today: today, now: now)
        }
        let failed = r.failed + settled.unsettled
        if r.rendered > 0 || failed > 0 {
            context.log("dashboard rendered=\(r.rendered) edited_outside_notes=\(r.editedOutsideNotes) failed=\(failed) unreadable=\(r.unreadable)")
        }
        if r.editedOutsideNotes > 0 {
            notify("Sprava", "A DASHBOARD.md was edited outside its Notes section. The edited copy was saved in the binder's .sprava folder.",
                   "dashboard-edited")
        }
        return outcome(r, settled: settled)
    }
}
