import Foundation
import Shelf
import SpravaKit

/// The deadline sentinel (architecture 3.4): reads every binder on the Shelf and records the day's counts under
/// opaque binder ids in `runtime/sentinel.json`. Reads binders only.
public enum SentinelJob {
    public static let shelfUnreadable = JobOutcome.error(code: "shelf_unreadable", culprit: nil)

    /// The run's outcome, and the day it covered when it ran (for `Scheduler.sentinelRan`). An empty Shelf is idle:
    /// nothing to watch yet. `idsLock` serializes the opaque id file with the other jobs that hand out ids.
    public static func run(rows: () throws -> [ShelfRow], support: URL, runtimeDir: URL, idsLock: NSLock,
                           now: Date, timeZone: TimeZone = .current) -> (outcome: JobOutcome, day: String?) {
        let today = CalendarDate.today(in: timeZone, now: now)
        let shelf: [ShelfRow]
        do { shelf = try rows() } catch { return (shelfUnreadable, nil) }
        let idsURL = support.appendingPathComponent("binder-ids.json")
        idsLock.lock()
        guard var ids = try? BinderIDs.load(idsURL) else {
            idsLock.unlock()
            return (.error(code: "binder_ids_unreadable", culprit: nil), nil)
        }
        let report = SentinelReport.compute(rows: shelf, ids: &ids, today: today, now: now, timeZone: timeZone)
        let savedIDs = Result { try ids.save(idsURL) }
        idsLock.unlock()
        do {
            try savedIDs.get()
            try save(report, runtimeDir: runtimeDir)
        } catch {
            return (.error(code: "write_failed", culprit: "\(error)"), nil)
        }
        // A binder that cannot be read is a finding, not a failed run.
        return (shelf.isEmpty ? .idle : .ok, today.description)
    }

    public static func reportURL(_ runtimeDir: URL) -> URL { runtimeDir.appendingPathComponent("sentinel.json") }

    static func save(_ report: SentinelReport, runtimeDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try StateFile.write(try encoder.encode(report), to: reportURL(runtimeDir))
    }

    /// Today's report, or nil when there is none for `today` or it cannot be read.
    public static func report(runtimeDir: URL, today: String) -> SentinelReport? {
        guard let report = try? StateFile.read(SentinelReport.self, from: reportURL(runtimeDir)), report.date == today else {
            return nil
        }
        return report
    }
}
