import Capture
import Clerk
import Extract
import Foundation
import Shelf
import SpravaKit

/// Tier 1 (architecture 5.3): the clerk reads the captures whose code-built cards are still untouched, then intake
/// documents, one at a time, starting new work only within `budget` seconds. Model calls never hold the command
/// queue. Gated on a model with a context of at least 8,192 tokens for the MVP (mvp.md question 7), unless
/// `developer.json` sets `"clerk_any_model": true`.
public enum ClerkJob {
    /// The outcome, and how many readings it made (the runtime records the model's last success when any). `engine` gives
    /// the engine that reads an intake document of a binder in the clerk's place, when there is one (decisions.md D40).
    public static func run(_ context: JobContext, model: Result<any ClerkModel, Error>, budget: TimeInterval = 45,
                           engine: @escaping @Sendable (URL) async -> (any DocumentEngine)? = { _ in nil },
                           clock: () -> Date = Date.init) -> (outcome: JobOutcome, read: Int) {
        guard let commands = context.commands else { return (context.noCommands, 0) }
        guard case .success(let model) = model else { return (.skipped, 0) }
        guard model.contextSize >= 8192 || anyModel(context.support) else { return (.skipped, 0) }
        let inbox = commands.inbox
        let filingList = FilingList(support: context.support)
        let started = clock()
        var read = 0
        while clock().timeIntervalSince(started) < budget {
            // A missing filing list is empty; an unreadable one must not consume an attempt or replace a
            // code-built card already filed using the person's hint.
            do { _ = try filingList.read() }
            catch { return (.error(code: "filing_list_unreadable", culprit: nil), read) }
            guard let rows = try? context.rows() else { return (SentinelJob.shelfUnreadable, read) }
            guard let work = context.onCommandQueue({ inbox.nextForClerk() }) else { break }
            // The binder the person named with the note is offered even off the list, so the clerk keeps the note
            // where the code-built card filed it (capture-event-v0 §8.1).
            let filing = work.filing(rows: rows, list: filingList, deviceID: commands.deviceID)
            let t0 = clock()
            let interp = waitFor { await Clerk(model: model).read(work.event, filing: filing, hint: work.hint) }
            let seconds = clock().timeIntervalSince(t0)
            let outcome = context.onCommandQueue {
                inbox.commitClerk(work, interp, filing: filing, rows: rows, commands: commands, seconds: seconds)
            }
            context.log("clerk outcome=\(interp.outcome) items=\(outcome.items) filed=\(outcome.filed) not_sure=\(outcome.unsure) calls=\(interp.calls) ms=\(Int(seconds * 1000))")
            read += 1
        }
        // Then intake documents (adaptation-layer §4.2, §4.3), started within the same budget.
        let watcher = IntakeWatcher(support: context.support)
        // The person's own addresses, from every binder's email connection: mail from them proposes no to-dos.
        let ownAddresses = BinderIMAPConnections.ownAddresses(support: context.support)
        while clock().timeIntervalSince(started) < budget {
            do { _ = try filingList.read() }
            catch { return (.error(code: "filing_list_unreadable", culprit: nil), read) }
            guard let rows = try? context.rows() else { return (SentinelJob.shelfUnreadable, read) }
            guard let entry = context.onCommandQueue({ watcher.nextForReading() }) else { break }
            let binder = filingList.binders(rows: rows, deviceID: commands.deviceID).first { $0.folder.standardizedFileURL.path == entry.binder }
                ?? rows.first { $0.folder.standardizedFileURL.path == entry.binder }.flatMap { row in
                    (try? filingList.name(of: row)).map {
                        FilingBinder(name: $0, description: "", folder: row.folder, words: [],
                                     openItems: FilingBinder.candidates(catalog: row.teka.catalog))
                    }
                }
            let t0 = clock()
            let locale = IntakeReading.language(of: entry.reading.text)
            let folder = URL(fileURLWithPath: entry.binder, isDirectory: true)
            let doc = waitFor {
                await Clerk(model: model).readDocument(entry.reading, name: entry.name, binder: binder, locale: locale,
                                                       ownAddresses: ownAddresses, engine: await engine(folder))
            }
            // Which engine read it, or the fixed reason it did not: never content.
            let by = (doc.readBy.map { " read_by=\($0)" } ?? "") + (doc.engineFailure.map { " engine_failure=\(logWord($0))" } ?? "")
            let seconds = clock().timeIntervalSince(t0)
            if doc.title == nil && doc.summary == nil && doc.items.isEmpty {
                context.onCommandQueue { watcher.failReading(entry) }
                context.log("clerk document outcome=failed calls=\(doc.calls)\(by) ms=\(Int(seconds * 1000))")
            } else {
                let outcome = context.onCommandQueue { watcher.commitReading(entry, doc, commands: commands) }
                context.log("clerk document outcome=\(doc.outcome) class=\(doc.documentClass) items=\(outcome.items) escalated=\(outcome.escalated) card_changed=\(outcome.cardChanged) calls=\(doc.calls)\(by) ms=\(Int(seconds * 1000))")
            }
            read += 1
        }
        return (.ok, read)
    }

    /// A reason as one log word: letters, digits and underscores only, at most 40.
    static func logWord(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(40))
    }

    /// The developer switch that lifts the model gate; read without following a link.
    static func anyModel(_ support: URL) -> Bool {
        guard case .ok(let data) = SafeFile.read(support.appendingPathComponent("developer.json"), limit: 64 * 1024) else { return false }
        return (try? JSONParser.parse(data).value["clerk_any_model"]) == .bool(true)
    }
}
