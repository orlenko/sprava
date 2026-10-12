import Foundation
import SpravaKit

/// The hourly check of what the Health page shows in red when it is off (architecture 3.7, 5.1): whether macOS
/// lets Sprava post notifications, and whether the on-device model is available.
public enum AlertsJob {
    /// `authorized` is nil outside the app bundle (a development run: no notification identity), recorded as
    /// skipped with alerts shown off. The clerk's last successful reading is kept across checks.
    public static func run(authorized: () -> Bool?, model: () -> Heartbeat.Model, lastModelSuccess: String?,
                           now: Date) -> (outcome: JobOutcome, alerts: Heartbeat.Alerts, model: Heartbeat.Model) {
        let allowed = authorized()
        var status = model()
        status.last_success = lastModelSuccess
        return (allowed == nil ? .skipped : .ok, Heartbeat.Alerts(authorized: allowed ?? false, checked_at: ISOTime.string(now)), status)
    }
}
