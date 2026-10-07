import Foundation

/// The manual addendum (teka-v0 §9.8, stricter as mvp.md question 13 asks): the person pastes it into a managed
/// binder's `CLAUDE.md` or `AGENTS.md`. Sprava never edits the manual. The first line is the marker the doctor
/// looks for.
public enum ManualAddendum {
    public static let marker = "<!-- sprava-managed v0 -->"

    public static let text = """
    \(marker)
    ## This binder is managed by Sprava

    This section overrides every older instruction in this file about `catalog.json`, `lifeproj drain`,
    `lifeproj publish` and `DASHBOARD.md`.

    - Never edit `catalog.json` by hand, not even to close an item or to add a log entry. Propose every change
      through Sprava's tools (`propose_ops`); the person approves it in the Sprava app.
    - To file a document, leave it in `intake/` and propose `file_document`; never move files into document
      folders yourself.
    - Do not run `lifeproj publish` or `lifeproj drain` in this binder. Sprava does both.
    - Edit `DASHBOARD.md` only below the line `## Notes`, and never regenerate it.

    """

    /// Whether the binder's manual carries the marker line (CLAUDE.md or AGENTS.md).
    public static func isPresent(in folder: URL) -> Bool? {
        var sawManual = false
        for name in ["CLAUDE.md", "AGENTS.md"] {
            guard case .ok(let data) = SafeFile.read(folder.appendingPathComponent(name), limit: 1024 * 1024) else { continue }
            sawManual = true
            if String(decoding: data, as: UTF8.self).contains(marker) { return true }
        }
        return sawManual ? false : nil
    }
}

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
        for row in rows where row.teka.isAdopted {
            let name = row.name
            let teka = row.teka
            if Owner.device(of: row.folder) != deviceID {
                out.append(Finding(level: .note, binder: name, text: "managed by another Mac or a development build; read-only here"))
                continue
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
