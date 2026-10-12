import Foundation
import SpravaKit

/// The daily summary (architecture 3.7): one notification with counts only, at most once per calendar day.
public enum SummaryJob {
    /// What the run needs from the runtime: today's sentinel report when there is one, the sentinel's breaker,
    /// a way to run the sentinel now, and the notifier (nil outside the app bundle, where there is no notification
    /// identity).
    public struct Inputs {
        public var today: String
        public var lastSent: String?
        public var report: () -> SentinelReport?
        public var sentinelBreaker: String?
        public var runSentinel: () -> Void
        public var notify: ((_ title: String, _ body: String, _ id: String) -> Bool)?

        public init(today: String, lastSent: String?, report: @escaping () -> SentinelReport?, sentinelBreaker: String?,
                    runSentinel: @escaping () -> Void, notify: ((String, String, String) -> Bool)?) {
            self.today = today
            self.lastSent = lastSent
            self.report = report
            self.sentinelBreaker = sentinelBreaker
            self.runSentinel = runSentinel
            self.notify = notify
        }
    }

    /// The outcome, and the day the summary counts as sent (for `Scheduler.summarySent` and `runtime/state.json`).
    public static func run(_ input: Inputs) -> (outcome: JobOutcome, sent: String?) {
        if input.lastSent == input.today { return (.skipped, nil) }
        // The sentinel may not have run yet today (a start just after midnight): compute it now, unless its breaker
        // is open, which this call must not get around.
        switch SummaryFallback.decide(reportFresh: input.report() != nil, sentinelBreaker: input.sentinelBreaker) {
        case .useReport: break
        case .runSentinel: input.runSentinel()
        case .stale: return (.error(code: "sentinel_stale", culprit: "sentinel breaker open"), nil)
        }
        guard let report = input.report() else { return (.error(code: "sentinel_stale", culprit: nil), nil) }
        if let text = report.summaryText {
            // A development run outside the app bundle skips, never fails.
            guard let notify = input.notify else { return (.skipped, nil) }
            guard notify("Sprava today", text, "summary-\(input.today)") else {
                return (.error(code: "notification_failed", culprit: nil), nil)
            }
        }
        return (.ok, input.today)
    }
}
