import BinderFormat
import BinderStore
import Capture
import Foundation
import Hub
import Shelf
import SpravaKit

/// The doctor's binder, catalog, runtime and hub checks (mvp.md feature 9, section 7 item 6). Findings name the
/// binder for the app; the runtime logs counts only.
public enum Doctor {
    public struct Finding: Sendable, Equatable {
        public enum Level: String, Sendable { case fix, note }
        public let level: Level
        public let binder: String?
        public let text: String
    }

    public static func run(rows: [ShelfRow], deviceID: String?, registry: LifeprojRegistry?, support: URL,
                           spool: URL? = nil) -> [Finding] {
        var out: [Finding] = []
        if spool == nil {
            out.append(Finding(level: rows.contains { $0.teka.isAdopted } ? .fix : .note, binder: nil,
                text: "the hub spool has not been configured here; its privacy checks are unavailable"))
        }
        let registered = Set((registry?.entries ?? []).compactMap { $0.workingDir }.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        })
        let colliding = HubLane.collidingFolders(rows, today: CalendarDate.today())
        for row in rows where row.teka.isAdopted {
            let name = row.name
            let teka = row.teka
            let inspection = HubLane.inspectPrivacy(teka, root: spool)
            out.append(contentsOf: sliceFindings(row, inspection: inspection))
            if registered.contains(row.folder.standardizedFileURL.resolvingSymlinksInPath().path) {
                if let privacy = inspection.privacy {
                    if privacy.disclosure != "full" {
                        out.append(Finding(level: .note, binder: name, text: "lifeproj can still reach this binder, so its disclosure \(privacy.disclosure) is not enforced there"))
                    } else if !privacy.lifted.isEmpty || !privacy.retitled.isEmpty || !privacy.retagged.isEmpty || !privacy.unkinded.isEmpty {
                        out.append(Finding(level: .note, binder: name, text: "lifeproj can still reach this binder, so its pending item privacy changes are not enforced there"))
                    }
                } else {
                    out.append(Finding(level: .note, binder: name, text: "lifeproj can still reach this binder; Health could not check its approved disclosure"))
                }
            }
            if deviceID == nil || Owner.device(of: row.folder) != deviceID {
                out.append(Finding(level: .note, binder: name, text: "managed by another Mac or a development build; read-only here"))
                continue
            }
            if colliding.contains(row.folder.standardizedFileURL.path) {
                out.append(Finding(level: .fix, binder: name, text: "another binder on the Shelf has the same name; neither publishes to nor drains from the hub until one is renamed"))
            }
            switch ManualAddendum.isPresent(in: row.folder) {
            case false?: out.append(Finding(level: .fix, binder: name, text: "the manual lacks Sprava's addendum; paste it from the binder's page"))
            case nil: out.append(Finding(level: .note, binder: name, text: "no CLAUDE.md or AGENTS.md; paste the addendum if an agent works here"))
            default: break
            }
            if teka.state < .needsMigration {
                out.append(Finding(level: .fix, binder: name, text: "\(teka.state.label): " + teka.reasons.joined(separator: "; ")))
            }
            if !teka.findings.isEmpty {
                out.append(Finding(level: .note, binder: name, text: "\(teka.findings.count) record(s) break the rules; repair cards wait"))
            }
            // A history that is not a plain file (a FIFO would block the read) is already reported by the state above.
            if !teka.writesBlocked, !OpLogBound.fits(row.folder) {
                out.append(Finding(level: .fix, binder: name, text: "the history is larger than \(OpLogBound.bytes >> 20) MB and was not read; undo is limited until it is repaired"))
            } else if !teka.writesBlocked, let bytes = DoctorReplayBudget.bytes(row.folder) {
                do {
                    let log = try TekaStore(folder: row.folder).readOpLog().ops
                    if !DoctorReplayBudget.fits(log, bytes: bytes) {
                        out.append(Finding(level: .note, binder: name, text: DoctorReplayBudget.finding))
                    } else {
                        if !log.isEmpty, (try? Replay.run(log)) == nil {
                            out.append(Finding(level: .fix, binder: name, text: "the history does not replay; undo is limited until it is repaired"))
                        }
                    }
                } catch {
                    out.append(Finding(level: .fix, binder: name, text: "the history cannot be read; undo is limited until it is repaired"))
                }
            } else if !teka.writesBlocked {
                out.append(Finding(level: .note, binder: name, text: DoctorReplayBudget.finding))
            }
            if DashboardKeeper(folder: row.folder).isSwitched == false {
                switch SafeFile.read(row.folder.appendingPathComponent("DASHBOARD.md")) {
                case .ok:
                    out.append(Finding(level: .note, binder: name, text: "DASHBOARD.md is kept by hand; Sprava can keep it after you approve the switch"))
                case .refused(let why), .unreadable(let why):
                    out.append(Finding(level: .fix, binder: name, text: "DASHBOARD.md cannot be read (\(why))"))
                case .missing: break
                }
            }
        }
        // Runtime: open breakers.
        let records = JobRecords.load(support.appendingPathComponent("runtime/breakers.json"))
        for (key, record) in records.jobs.sorted(by: { $0.key < $1.key }) where record.breaker == "open" {
            out.append(Finding(level: .fix, binder: nil, text: "the \(key) job keeps failing and is paused (\(record.lastErrorCode ?? "error"))"))
        }
        // Captures waiting too long (mvp.md 1.2, currency).
        let inbox = CaptureInbox(root: CaptureInbox.defaultRoot(support: support), support: support)
        let health = inbox.health()
        if let error = health.error {
            out.append(Finding(level: .fix, binder: nil, text: error))
        } else if let oldest = health.oldestUnfiledSeconds, oldest > 7 * 86_400 {
            out.append(Finding(level: .note, binder: nil, text: "a card has waited in the Inbox for more than 7 days"))
        }
        if health.error == nil, health.quarantined > 0 {
            out.append(Finding(level: .note, binder: nil, text: "\(health.quarantined) capture file(s) were set aside as malformed"))
        }
        return out
    }

    /// Hub owns the names, privacy projection and state reads for every binder, including another Mac's.
    private static func sliceFindings(_ row: ShelfRow, inspection: HubLane.PrivacyInspection) -> [Finding] {
        inspection.issues.map { issue in
            let text: String
            switch issue {
            case .privateSlice(let disclosure):
                text = "this binder's disclosure is \(disclosure), but its slice is still on the hub"
            case .unknownPrivacy:
                text = "this binder's slice is still on the hub, but Health could not confirm its approved disclosure"
            case .showsMore:
                text = "this binder's slice on the hub shows more than its current privacy allows"
            case .otherPublisher:
                text = "another program publishes this binder's slice (an old lifeproj?)"
            case .unavailable:
                text = "this binder's slice on the hub cannot be read or safely checked"
            }
            return Finding(level: .fix, binder: row.name, text: text)
        }
    }

}

/// Health is synchronous. Bound both the input and repeated catalog work before asking Replay to check it.
/// JSON Patch accepts only literal add/remove/replace, so catalog growth is bounded by values in the log.
enum DoctorReplayBudget {
    static let finding = "the history exceeds Health's check budget and was not replayed; its files were left as they are"

    static func bytes(_ folder: URL) -> Int? {
        var info = stat()
        guard lstat(folder.appendingPathComponent(".sprava/ops.ndjson").path, &info) == 0 else {
            return errno == ENOENT ? 0 : nil
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 1 << 20 else { return nil }
        return Int(info.st_size)
    }

    static func fits(_ log: [JSONObject], bytes: Int) -> Bool {
        guard log.count <= 100 else { return false }
        var units = max(1, log.count)
        for op in log {
            units += op["args"]?["patch"]?.arrayValue?.count ?? 0
            units += op["args"]?["set"]?.objectValue?.entries.count ?? 0
            units += op["args"]?["unset"]?.arrayValue?.count ?? 0
            guard units <= 500 else { return false }
        }
        return bytes <= (4 << 20) / units
    }
}

/// The readers (Doctor, Measures) load the whole op log into memory; one larger than this is reported, never read.
enum OpLogBound {
    static let bytes = 64 << 20

    /// True when the op log is absent or a regular file no larger than `bytes` (checked before any read).
    static func fits(_ folder: URL) -> Bool {
        var info = stat()
        guard lstat(folder.appendingPathComponent(".sprava/ops.ndjson").path, &info) == 0 else { return true }
        return info.st_mode & S_IFMT == S_IFREG && info.st_size <= bytes
    }
}
