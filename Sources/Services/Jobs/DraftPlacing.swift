import BinderStore
import Capture
import Foundation
import SpravaKit

/// Places approved email drafts in the account's Drafts folder (integrations.md §5.2, decisions.md D41), one at a time,
/// from the runtime's email owner. This is the step that leaves the Mac (A7); Sprava never sends.
enum DraftPlacing {
    typealias Place = @Sendable (BinderIMAPConnections.Configuration, String, Data, URL) throws -> IMAPDraftAppend.Placed
    static let native: Place = { config, password, message, directory in
        try IMAPDraftAppend.run(config, password: password, folder: nil, message: message, directory: directory)
    }
    /// A request still `approving` this long after it was written belongs to an approval that did not finish.
    static let settleAfter: TimeInterval = 600

    /// Whether card `id`'s approval went through: its ops are in the binder's log (an approval writes them before it
    /// marks the card), or the card says applied. False only when the card is readable, still proposed or rejected, and
    /// the log holds none of its ops; nil when that cannot be told.
    static func approved(_ id: String, in folder: URL) -> Bool? {
        guard let log = try? TekaStore(folder: folder).readOpLog(), !log.torn else { return nil }
        let aborted = Set(log.ops.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        if log.ops.contains(where: { $0["proposal"]?.stringValue == id && !aborted.contains($0["id"]?.stringValue ?? "") }) { return true }
        switch ProposalStore.list(in: folder).first(where: { $0.0.id == id })?.0.state {
        case "applied": return true
        case "proposed", "rejected": return false
        default: return nil
        }
    }

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
            case false?: try? requests.remove(id: request.id)
            case nil: continue   // not known: kept, and the person can discard it from the binder's page
            }
        }
        // The oldest that can go now: one whose binder is away or whose password is not here does not hold up the rest.
        let ready = requests.all().filter { $0.state == .ready }.sorted { $0.created < $1.created }
        var chosen: (DraftRequests.Request, BinderIMAPConnections.Configuration, String)?
        for request in ready where chosen == nil {
            let folder = URL(fileURLWithPath: request.binder, isDirectory: true)
            guard (try? available(folder)) == true else { continue }
            // An unreadable connection list waits; only a binder with no connection fails.
            guard let found = try? connections.configuration(for: folder) as BinderIMAPConnections.Configuration?? else { continue }
            guard let config = found else {
                try? requests.failed(id: request.id, reason: "no email connection")
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
            let placed = try place(config, secret, try requests.message(id: request.id), attempt)
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
            // The server, the network or a limit: it is tried again on the next run, and finds itself if it got there.
            return .waiting
        }
    }
}
