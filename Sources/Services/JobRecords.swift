import Darwin
import Foundation
import SpravaKit

/// The store behind `runtime/breakers.json`.
public struct JobRecords: Codable, Sendable {
    public var jobs: [String: JobRecord] = [:]

    public init() {}

    /// For display and tests only: an unreadable file reads as no records. The runtime starts through `loadAtStart`,
    /// which never treats an unreadable file as closed breakers.
    static func load(_ url: URL) -> JobRecords {
        (try? read(url)) ?? JobRecords()
    }

    /// The records; a missing file is none, and a file that exists but cannot be read or decoded (a link among
    /// them) throws `StateFile.Unreadable`.
    static func read(_ url: URL) throws -> JobRecords {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var records = try StateFile.read(JobRecords.self, from: url, decoder: decoder) else { return JobRecords() }
        // A job recorded as running when the process died is not running now.
        for key in records.jobs.keys { records.jobs[key]?.running = false }
        return records
    }

    /// The runtime's start. Breakers that cannot be read are not reset to closed, which would let a job that
    /// wedges restart the runtime again: the file is kept aside as `breakers.json.unreadable-<time>`, and every job
    /// starts half-open, so each gets one trial run and its breaker opens again on a failure. Starting never fails,
    /// which would bring back the launchd restart loop. Returns where the file was put, when it could be.
    public static func loadAtStart(_ url: URL, jobs: [String], now: Date = Date()) -> (JobRecords, setAside: URL?) {
        if let records = try? read(url) { return (records, nil) }
        var records = JobRecords()
        for key in jobs { records.jobs[key, default: JobRecord()].breaker = "half_open" }
        return (records, UnreadableStateFile.setAside(url, now: now))
    }

    /// Records a watchdog exit straight to disk, without the runtime's state queue, which may be the thing that hung.
    /// It takes no lock: the watchdog must never wait on anything the hung state queue may hold.
    public static func recordWatchdogExit(job: String, threshold: Int, url: URL, now: Date = Date()) {
        // An unreadable file is left for the next start to set aside, never saved over.
        guard var records = try? read(url) else { return }
        records.jobs[job, default: JobRecord()].recordWatchdogExit(at: now, threshold: threshold)
        try? records.save(url)
    }

    /// Refuses to replace a file that cannot be read: one the start could not set aside is never saved over.
    public func save(_ url: URL) throws {
        _ = try Self.read(url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try StateFile.write(try encoder.encode(self), to: url)
    }
}

/// The runtime's state files that cannot be read at its start.
enum UnreadableStateFile {
    /// Renames the file to `<name>.unreadable-<UTC time>` beside it, through a handle on its folder: a link in its
    /// place is moved, not followed, and a folder that is itself a link (or not this user's) is left untouched.
    /// Nil when it could not be moved.
    static func setAside(_ url: URL, now: Date) -> URL? {
        let stamp = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!).replacingOccurrences(of: ":", with: "")
        let name = url.lastPathComponent + ".unreadable-" + stamp
        guard let folder = try? StateDirectory.open(url.deletingLastPathComponent()),
              (try? folder.rename(url.lastPathComponent, to: name)) != nil else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }
}
