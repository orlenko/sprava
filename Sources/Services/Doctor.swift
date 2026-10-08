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

    public static func run(rows: [ShelfRow], deviceID: String, registry: LifeprojRegistry?, support: URL,
                           spool: URL = HubLane.spoolRoot()) -> [Finding] {
        var out: [Finding] = []
        let registered = Set((registry?.entries ?? []).compactMap { $0.workingDir }.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
        })
        let colliding = HubLane.collidingFolders(rows, today: CalendarDate.today())
        for row in rows where row.teka.isAdopted {
            let name = row.name
            let teka = row.teka
            if Owner.device(of: row.folder) != deviceID {
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
            if let log = try? TekaStore(folder: row.folder).readOpLog().ops, !log.isEmpty, (try? Replay.run(log)) == nil {
                out.append(Finding(level: .fix, binder: name, text: "the history does not replay; undo is limited until it is repaired"))
            }
            let disclosure = teka.catalog?["meta"]?["disclosure"]?.stringValue ?? "full"
            if registered.contains(row.folder.standardizedFileURL.path), disclosure != "full" {
                out.append(Finding(level: .note, binder: name, text: "lifeproj can still reach this binder, so its disclosure \(disclosure) is not enforced there"))
            }
            // The slice another program wrote over ours (architecture 11).
            if teka.catalog?["meta"]?["disclosure"]?.stringValue != "none", HubLane.isSafeSegment(name),
               let data = try? Data(contentsOf: spool.appendingPathComponent("inbox/\(name).agenda.json")),
               let value = try? JSONParser.parse(data).value, let hash = try? Canonical.hash(HubLane.stripGenerated(value)),
               let ours = HubLane.loadCursors(row.folder).sliceHash, hash != ours {
                out.append(Finding(level: .fix, binder: name, text: "another program publishes this binder's slice (an old lifeproj?)"))
            }
            if DashboardKeeper(folder: row.folder).isSwitched == false,
               (try? Data(contentsOf: row.folder.appendingPathComponent("DASHBOARD.md"))) != nil {
                out.append(Finding(level: .note, binder: name, text: "DASHBOARD.md is kept by hand; Sprava can keep it after you approve the switch"))
            }
        }
        // Runtime: open breakers.
        let records = JobRecords.load(support.appendingPathComponent("runtime/breakers.json"))
        for (key, record) in records.jobs.sorted(by: { $0.key < $1.key }) where record.breaker == "open" {
            out.append(Finding(level: .fix, binder: nil, text: "the \(key) job keeps failing and is paused (\(record.lastErrorCode ?? "error"))"))
        }
        // Captures waiting too long (mvp.md 1.2, currency).
        let inbox = CaptureInbox(root: CaptureInbox.defaultRoot(support: support), support: support)
        if let oldest = inbox.health().oldestUnfiledSeconds, oldest > 7 * 86_400 {
            out.append(Finding(level: .note, binder: nil, text: "a card has waited in the Inbox for more than 7 days"))
        }
        if inbox.health().quarantined > 0 {
            out.append(Finding(level: .note, binder: nil, text: "\(inbox.health().quarantined) capture file(s) were set aside as malformed"))
        }
        return out
    }
}

/// The development CLI's safety check: its commands never touch a folder lifeproj's registry lists. A registry
/// that exists but cannot be read refuses everything, since it might list the folder; only an absent one allows.
public enum DevelopmentGuard {
    /// Why development commands refuse `folder`, or nil when they may run.
    public static func refusal(for folder: URL, registryURL: URL = LifeprojRegistry.defaultPath()) -> String? {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return nil }
        let registry: LifeprojRegistry
        do { registry = try LifeprojRegistry.load(from: registryURL) } catch {
            return "lifeproj's registry exists but cannot be read; development commands refuse to run"
        }
        // Compared after resolving links, so a link to a live binder is refused too.
        func real(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        }
        let target = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if registry.entries.contains(where: { $0.workingDir.map(real) == target }) {
            return "\(folder.path) is in lifeproj's registry; development commands work on invented copies only"
        }
        return nil
    }
}
