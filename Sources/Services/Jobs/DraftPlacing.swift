import BinderStore
import Capture
import Foundation
import SpravaKit

/// Places approved email drafts in the account's Drafts folder (integrations.md §5.2, decisions.md D41), one at a time,
/// from the runtime's email owner. This is the step that leaves the Mac (A7); Sprava never sends.
enum DraftPlacing {
    /// The connection, the Drafts folder the person chose (nil: the one the server marks), the password, the message,
    /// and the attempt's private folder.
    typealias Place = @Sendable (BinderIMAPConnections.Configuration, String?, String, Data, URL) throws -> IMAPDraftAppend.Placed
    static let native: Place = { config, folder, password, message, directory in
        try IMAPDraftAppend.run(config, password: password, folder: folder, message: message, directory: directory)
    }
    /// A request still `approving` this long after it was written belongs to an approval that did not finish.
    static let settleAfter: TimeInterval = 600

    /// Whether card `id`'s approval went through, from the binder's op log alone: an approval writes its ops before it
    /// marks the card, and the card file is not proof. Nil when the log cannot be read.
    static func approved(_ id: String, in folder: URL) -> Bool? {
        guard let log = try? TekaStore(folder: folder).readOpLog(), !log.torn else { return nil }
        let aborted = Set(log.ops.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        return log.ops.contains { $0["proposal"]?.stringValue == id && !aborted.contains($0["id"]?.stringValue ?? "") }
    }

    /// Placements with no known answer are spaced out by this, and after `maximumAttempts` the person is told.
    static let retryAfter: TimeInterval = 300
    static let maximumAttempts = 3

    /// What one run did, in fixed words: logged, and never content.
    enum Outcome: String, Equatable { case placed, present, waiting, failed, none }

    /// Settles requests an approval left half-done, then places the oldest ready one.
    static func run(support: URL, connections: BinderIMAPConnections, password: (IMAPAccount) throws -> String?,
                    available: (URL) throws -> Bool, place: Place, now: Date = Date()) -> Outcome {
        let requests = DraftRequests(support: support)
        let all = requests.all()
        for request in all where request.state == .approving && now.timeIntervalSince(request.created) > settleAfter {
            let folder = URL(fileURLWithPath: request.binder, isDirectory: true)
            guard (try? available(folder)) == true else { continue }
            switch approved(request.id, in: folder) {
            case true?: try? requests.ready(id: request.id)
            case false?: try? requests.remove(id: request.id, ifCreated: request.created)
            case nil: continue   // not known: kept, and the person can discard it from the binder's page
            }
        }
        // The oldest that can go now: one whose binder is away or whose password is not here does not hold up the rest.
        let ready = requests.all().filter { $0.state == .ready }.sorted { $0.created < $1.created }
        var chosen: (DraftRequests.Request, BinderIMAPConnections.Configuration, String)?
        for request in ready where chosen == nil {
            // One that ended with no known answer lately waits its turn, and does not hold up the rest.
            if let tried = request.tried, now.timeIntervalSince(tried) < retryAfter { continue }
            let folder = URL(fileURLWithPath: request.binder, isDirectory: true)
            guard (try? available(folder)) == true else { continue }
            // An unreadable connection list waits; only a binder with no connection fails.
            guard let found = try? connections.configuration(for: folder) as BinderIMAPConnections.Configuration?? else { continue }
            guard let config = found else {
                try? requests.failed(id: request.id, reason: "no email connection")
                continue
            }
            // It was approved for one account: if the binder's connection is another now, it goes nowhere until the
            // person approves it again.
            guard DraftRequests.account(of: config.account) == request.account else {
                try? requests.failed(id: request.id, reason: "account changed")
                continue
            }
            // A password this runtime does not have waits for the person; the server is never tried without it.
            guard let secret = try? password(config.account) else { continue }
            chosen = (request, config, secret)
        }
        guard let (request, config, secret) = chosen else { return ready.isEmpty ? .none : .waiting }
        let attempt = support.appendingPathComponent("capture/draft-attempts/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: attempt) }
        do {
            try AtomicFile.makePrivateFolder(attempt.deletingLastPathComponent())
            try AtomicFile.makePrivateFolder(attempt)
            let placed = try place(config, config.draftsFolder, secret, try requests.message(id: request.id), attempt)
            try requests.remove(id: request.id)
            return placed.present ? .present : .placed
        } catch let refused as IMAPDraftAppend.Refused {
            try? requests.failed(id: request.id, reason: refused == .noDraftsFolder ? "no drafts folder" : "message refused")
            return .failed
        } catch IMAPIntakeImport.Refused.authentication {
            try? requests.failed(id: request.id, reason: "sign-in refused")
            return .failed
        } catch IMAPIntakeImport.Refused.untrusted {
            try? requests.failed(id: request.id, reason: "certificate changed")
            return .failed
        } catch DraftRequests.Refused.missing {
            try? requests.failed(id: request.id, reason: "message missing")
            return .failed
        } catch {
            // The server, the network, a limit, or a refusal with no word for it: tried again later, and it finds itself
            // if it got there. After a few, the person is told; Try again starts the count afresh.
            try? requests.attempted(id: request.id, at: now)
            if request.attempts + 1 >= maximumAttempts {
                try? requests.failed(id: request.id, reason: "not placed: the server refused it or did not answer")
                return .failed
            }
            return .waiting
        }
    }
}
