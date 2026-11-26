import BinderStore
import CryptoKit
import Foundation
import SpravaKit

/// What a binder's turns did, as counts by code and nothing else (decisions.md D47): no path, host, command or text.
/// A binder is named by a hash of its folder's path and a script by a hash of its path in the binder. Kept in
/// `runtime/improvement-counts.sqlite`. Sprava's own state: a count lost with it only delays a suggestion.
final class ImprovementCounts: Sendable {
    /// A turn in which some script of the binder was started.
    static let scriptRun = "script_run"
    /// A site a turn asked for that the person, or the lack of an answer, refused.
    static let hostRefused = "host_refused"
    /// The turns in which one script was started.
    static func script(_ path: String) -> String { "script:" + hash(path) }

    private let store: StateStore
    private static let schema = StateStore.Schema(version: 1, statements: [
        "CREATE TABLE counts (binder TEXT NOT NULL, code TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (binder, code)) STRICT"
    ])
    init(at url: URL) throws { store = try StateStore.open(url, schema: Self.schema) }

    private static func hash(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Adds to one count of one binder and answers what it is now.
    @discardableResult
    func add(_ folder: URL, _ code: String, by amount: Int = 1) throws -> Int {
        let binder = Self.hash(folder.standardizedFileURL.path)
        return try store.write { t in
            try t.execute("INSERT INTO counts VALUES (?, ?, ?) ON CONFLICT (binder, code) DO UPDATE SET count = count + excluded.count",
                          .text(binder), .text(code), .integer(Int64(amount)))
            return Int(try t.rows("SELECT count FROM counts WHERE binder = ? AND code = ?", .text(binder), .text(code)).first?.first?.integer ?? 0)
        }
    }

    /// Every count of one binder, by code.
    func read(_ folder: URL) throws -> [String: Int] {
        let binder = Self.hash(folder.standardizedFileURL.path)
        return try store.read { t in
            Dictionary(try t.rows("SELECT code, count FROM counts WHERE binder = ?", .text(binder)).compactMap { row in
                guard let code = row.first?.text, let count = row.last?.integer else { return nil }
                return (code, Int(count))
            }, uniquingKeysWith: { first, _ in first })
        }
    }
}

/// A turn's counts, and the suggestion Sprava makes of its own from them: a script started in many turns is a job
/// done by hand, so at its 5th counted turn, and once more at its 25th, the binder gets a suggestion card with the
/// script's text, for the person to read, edit, send or dismiss like any other.
enum ClaudeScriptRuns {
    static let suggestAt: Set<Int> = [5, 25]

    /// `ran` holds what the turn's commands started, as written: only a script the binder holds counts, once a turn.
    /// A script a card may carry: inside the binder with no link on the way, under `scripts/` or named as a script,
    /// no key file, readable as at most 32 KiB.
    static func note(_ ran: [String], refusedHosts: Int, folder: URL, counts: ImprovementCounts, writer: ClaudeTodoWriter) {
        if refusedHosts > 0 { try? counts.add(folder, ImprovementCounts.hostRefused, by: refusedHosts) }
        let root = folder.standardizedFileURL.path + "/"
        var scripts: [String] = []
        for written in ran {
            let path = written.hasPrefix(root) ? String(written.dropFirst(root.count)) : written
            guard !scripts.contains(path), SuggestionCard.isScriptPath(path),
                  case .ok = SafeFile.read(folder.appendingPathComponent(path), under: folder, limit: SuggestionCard.maxScript) else { continue }
            scripts.append(path)
        }
        guard !scripts.isEmpty else { return }
        try? counts.add(folder, ImprovementCounts.scriptRun)
        for path in scripts {
            guard let runs = try? counts.add(folder, ImprovementCounts.script(path)), suggestAt.contains(runs) else { continue }
            let name = String((path as NSString).lastPathComponent.prefix(80))
            let args = JSONObject([
                (key: "title", value: .string("Build in what the script \u{201C}\(name)\u{201D} does")),
                (key: "attempted", value: .string("The script \(path) was started in \(runs) turns of this binder's conversation.")),
                (key: "obstacle", value: .str("It is started by hand each time. Sprava has nothing built in for this job, and no schedule to run it on.")),
                (key: "script", value: .string(path)),
            ])
            // A card that cannot be made (too many waiting, a title already there) is left out: the count stays.
            _ = try? ClaudeSuggestionTool.suggest(args, folder: folder, writer: writer, counted: true)
        }
    }
}
