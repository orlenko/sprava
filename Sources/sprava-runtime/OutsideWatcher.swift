import AppKit
import Darwin
import Foundation
import SpravaCore

/// `sprava-runtime --watch`: a second launchd job that runs every 15 minutes, reads the heartbeat, and posts
/// at most one notification a day when the runtime has been silent for 15 minutes and the app is not running
/// (architecture 3.3). Its only write is `runtime/watch.json`.
struct OutsideWatcher {
    let runtimeDir: URL

    struct Record: Codable {
        var ran_at: String
        var saw: String
        var beat_age_s: Int?
        var notified_on: String?
    }

    func runOnce() -> Int32 {
        let recordURL = runtimeDir.appendingPathComponent("watch.json")
        let previous = (try? Data(contentsOf: recordURL)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }

        // Right after a wake, give the runtime two minutes to write its wake beat before judging.
        if let wake = lastWake(), Date().timeIntervalSince(wake) < 120 {
            Thread.sleep(forTimeInterval: 120 - Date().timeIntervalSince(wake))
        }

        var saw = "ok"
        var age: Int?
        switch Heartbeat.read(runtimeDir.appendingPathComponent(Heartbeat.fileName)) {
        case .failure(.missing): saw = "no_heartbeat"
        case .failure(.invalid): saw = "heartbeat_unreadable"
        case .success(let beat):
            let beatAt = ISOTime.date(beat.beat_at) ?? .distantPast
            let since = max(beatAt, lastWake() ?? .distantPast)
            age = Int(Date().timeIntervalSince(since))
            if !ProcessCheck.isAlive(pid: beat.pid, startedAt: ISOTime.date(beat.started_at)) {
                saw = "pid_dead"
            } else if (age ?? 0) > 900 {
                saw = "stale"
            }
        }

        var notifiedOn = previous?.notified_on
        let today = CalendarDate(Date(), in: .current).description
        let appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "ca.orlenko.sprava").isEmpty
        if saw != "ok", !appRunning, notifiedOn != today, !UserChoice.backgroundOff(runtimeDir) {
            let when = age.map { $0 >= 3600 ? "\($0 / 3600) hours ago" : "\($0 / 60) minutes ago" } ?? "a while ago"
            if Notifier.post(title: "Sprava",
                             body: "Sprava's background work stopped \(when). Open Sprava to restart it.",
                             id: "watch-\(today)") {
                notifiedOn = today
            }
        }
        let record = Record(ran_at: ISOTime.string(Date()), saw: saw, beat_age_s: age, notified_on: notifiedOn)
        if let data = try? JSONEncoder().encode(record) { try? AtomicFile.write(data, to: recordURL) }
        return 0
    }

    /// `sysctl kern.waketime`.
    func lastWake() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.waketime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}

/// The person's own "background work off" choice, written by the app; an exit never means "stay off".
enum UserChoice {
    static func backgroundOff(_ runtimeDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: runtimeDir.appendingPathComponent("background-off").path)
    }
}
