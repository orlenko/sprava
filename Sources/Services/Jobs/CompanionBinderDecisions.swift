import BinderFormat
import BinderStore
import Capture
import Companion
import Foundation
import SpravaKit

/// companion-v0 §§9.5–9.6 for the runtime: what a phone's request does to a binder or the capture inbox. Under the
/// binder's write lock it authorizes the request against the binder as it is now, prepares the exact effect (an op,
/// a capture event or a card), and hands it to the executor, which records it durably before `apply` writes it.
/// After a crash it classifies a recorded op under the same lock and never applies one that may have taken effect.
struct CompanionBinderDecisions: CompanionDecisionAdapter, Sendable {
    let profile: CompanionProfile
    let support: URL
    /// This Mac's device id: only binders it owns are written.
    let deviceID: String
    let client: String
    let timeZone: TimeZone
    let clock: @Sendable () -> Date

    init(profile: CompanionProfile, support: URL, deviceID: String, client: String = "sprava/0.1",
         timeZone: TimeZone = .current, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.profile = profile; self.support = support; self.deviceID = deviceID
        self.client = client; self.timeZone = timeZone; self.clock = clock
    }

    func withPreparedDecision<Result>(for request: CompanionAuthenticatedRequest,
        _ body: (CompanionDecisionPlan, (CompanionDecisionRecord) throws -> Void) throws -> Result) throws -> Result {
        guard let action = request.action else { throw CompanionDecisionError.invalid }
        if action.kind == .note { return try prepareNote(request, action, body) }
        guard let binderID = action.binderID else { throw CompanionDecisionError.invalid }
        switch try place(of: binderID) {
        case .gone, .shown(_, false):
            return try body(CompanionDecisionPlan(outcome: .rejected, effect: .rejection(.notShown)), refuse)
        case .away: throw CompanionDeviceDecisionFailure.binderUnavailable
        case .shown(let folder, true):
            return try inBinder(folder) { transaction in
                let plan = try authorize(request, action, binderID: binderID, transaction)
                return try body(plan) { try apply($0, in: folder, transaction) }
            }
        }
    }

    func withRecoveredDecision<Result>(for record: CompanionDecisionRecord,
        _ body: (CompanionDecisionProof, (CompanionDecisionRecord) throws -> Void) throws -> Result) throws -> Result {
        let request = record.request
        switch record.plan.effect {
        case .capture: return try body(.idempotent) { try publishNote($0) }
        case .none, .rejection: throw CompanionDecisionError.invalid
        case .conflict, .operation: break
        }
        guard let action = request.action, let binderID = action.binderID else { throw CompanionDecisionError.invalid }
        // A binder switched off since still gets its card or its proof; one whose folder cannot be found waits.
        guard case .shown(let folder, _) = try place(of: binderID) else { throw CompanionDeviceDecisionFailure.binderUnavailable }
        return try inBinder(folder) { transaction in
            let write = { (record: CompanionDecisionRecord) throws in try apply(record, in: folder, transaction) }
            guard case .operation(_, let effectID, _) = record.plan.effect else { return try body(.idempotent, write) }
            switch try transaction.proof(effectID: effectID, tag: Self.tag(request)) {
            case .tookEffect: return try body(.applied, refuse)
            case .notApplied: return try body(.notApplied(try authorize(request, action, binderID: binderID, transaction)), write)
            case .unknown:
                let card = try CompanionConflictCard.bytes(for: request, label: label(request.deviceID), reason: .interrupted,
                    catalog: try transaction.currentState().catalog, client: client, now: clock())
                return try body(.uncertain(conflict: card), write)
            }
        }
    }

    // MARK: Binder items

    /// §9.5 under the binder's write lock: the outcome and the complete effect, written nowhere yet.
    private func authorize(_ request: CompanionAuthenticatedRequest, _ action: CompanionRequestedAction, binderID: String,
                           _ transaction: CompanionOperationTransaction) throws -> CompanionDecisionPlan {
        let catalog = try transaction.currentState().catalog
        let open = catalog["open_items"]?.arrayValue ?? []
        // Every closure entry, not only the recent ones a view shows: a request on any closed item is decided as one.
        let closed = (catalog["processing_log"]?.arrayValue ?? []).filter { $0["id"] != nil }
        let reading = CompanionItemReading(openItems: open, closedItems: closed,
                                           today: CalendarDate.today(in: timeZone, now: clock()).description)
        func conflict(_ reason: CompanionConflictCard.Reason) throws -> CompanionDecisionPlan {
            CompanionDecisionPlan(outcome: .conflict, effect: .conflict(bytes: try CompanionConflictCard.bytes(
                for: request, label: label(request.deviceID), reason: reason, catalog: catalog, client: client, now: clock())))
        }
        switch try profile.authorizeItemAction(action, reading: reading) {
        case .rejected(let reason): return CompanionDecisionPlan(outcome: .rejected, effect: .rejection(reason))
        case .alreadyApplied: return CompanionDecisionPlan(outcome: .applied, effect: .none)
        case .conflict: return try conflict(.changed)
        case .mutation(let mutation):
            guard let item = open.first(where: { CompanionConflictCard.same($0["id"], action.itemID) }), let id = item["id"] else {
                throw CompanionDecisionError.invalid
            }
            // The Mac shows a repeating item read-only, and nothing computes its next date (binder-v0 §5.4), so any
            // change to it waits for the person.
            if item["recurrence"] != nil { return try conflict(.repeating) }
            let effectID = UUID().uuidString.lowercased()
            do {
                let bytes = try transaction.prepare(Self.body(mutation, id: id), effectID: effectID, tag: Self.tag(request), now: clock())
                return CompanionDecisionPlan(outcome: .applied, effect: .operation(binderID: binderID, id: effectID, bytes: bytes))
            } catch is TransactionGuard.Rejection {
                return try conflict(.refused)
            }
        }
    }

    /// The op of §9.5's table, and nothing else; `prepare` adds `closed_at`, `source` and the client.
    static func body(_ mutation: CompanionItemMutation, id: JSONValue) -> TekaStore.OpBody {
        let actor = JSONObject([("kind", .str("user"))])
        switch mutation {
        case .complete: return TekaStore.OpBody(op: "complete", args: JSONObject([("id", id)]), actor: actor)
        case .drop: return TekaStore.OpBody(op: "drop", args: JSONObject([("id", id)]), actor: actor)
        case .followUp(let date):
            return TekaStore.OpBody(op: "update_item", args: JSONObject([("id", id), ("set", .obj([("follow_up_at", .string(date))]))]), actor: actor)
        case .postpone(let date):
            return TekaStore.OpBody(op: "update_item", args: JSONObject([("id", id), ("set", .obj([("due", .string(date))]))]), actor: actor)
        case .arrived: return TekaStore.OpBody(op: "set_status", args: JSONObject([("id", id), ("status", .str("open"))]), actor: actor)
        }
    }

    static func tag(_ request: CompanionAuthenticatedRequest) -> String { "companion:\(request.deviceID)/\(request.requestID)" }

    /// Writes exactly the recorded effect, under the lock the plan was made under.
    private func apply(_ record: CompanionDecisionRecord, in folder: URL, _ transaction: CompanionOperationTransaction) throws {
        switch record.plan.effect {
        case .operation(_, _, let bytes): try transaction.applyRecorded(bytes)
        case .conflict(let bytes): try CompanionConflictCard.write(bytes, in: folder, commands: Commands(support: support, deviceID: deviceID, client: client))
        case .capture: try publishNote(record)
        case .none, .rejection: break
        }
    }

    // MARK: Notes

    /// §9.5 for `note`: always applied, as a capture event the clerk files, naming the binder only while it is shown.
    private func prepareNote<Result>(_ request: CompanionAuthenticatedRequest, _ action: CompanionRequestedAction,
        _ body: (CompanionDecisionPlan, (CompanionDecisionRecord) throws -> Void) throws -> Result) throws -> Result {
        guard let text = action.text else { throw CompanionDecisionError.invalid }
        var hint: String?
        if let binderID = action.binderID, case .shown(let folder, true) = try place(of: binderID) {
            let catalog = Teka.read(folder).catalog
            if case .string(let name)? = catalog?["meta"]?["name"], !name.isEmpty { hint = name } else { hint = folder.lastPathComponent }
        }
        let note = try producer.prepareCompanionNote(text, companionDeviceID: request.deviceID, requestID: request.requestID,
                                                     shownBinderName: hint, now: clock())
        return try body(CompanionDecisionPlan(outcome: .applied, effect: .capture(id: note.id, bytes: note.bytes))) { try publishNote($0) }
    }

    private func publishNote(_ record: CompanionDecisionRecord) throws {
        guard case .capture(let id, let bytes) = record.plan.effect else { throw CompanionDecisionError.invalid }
        try producer.publishRecordedCompanionNote(bytes, effectID: id, companionDeviceID: record.request.deviceID,
                                                  requestID: record.request.requestID)
    }

    private var producer: CaptureProducer {
        CaptureProducer(root: CaptureInbox.defaultRoot(support: support), deviceID: deviceID, support: support)
    }

    // MARK: Finding the binder

    enum Place {
        /// The folder recorded for the phone id, still the same folder and owned by this Mac; `shown` is the switch.
        case shown(URL, Bool)
        /// No folder for this id any more: never made here, or another folder now at its path.
        case gone
        /// Offloaded for now, or held by another Mac: its requests wait.
        case away
    }

    /// The binder behind a phone id, from Sprava's own records only (§9.5 rule 1), never from the request.
    func place(of binderID: String) throws -> Place {
        guard let local = try profile.localBinder(phoneID: binderID) else { return .gone }
        guard let entry = try CompanionBinderIdentities(support: support).all().first(where: { $0.identity == local.identity }) else {
            return .gone
        }
        switch entry.match {
        case .replaced: return .gone
        case .missing: return .away
        case .same:
            guard Commands.ownerDevice(of: entry.folder) == deviceID else { return .away }
            return .shown(entry.folder, local.state == .shown)
        }
    }

    /// Runs `body` under the binder's write lock, settled. A binder that is busy, needs attention or refuses the write
    /// makes this device wait and retry (§9.2); every other failure stays what it is.
    private func inBinder<T>(_ folder: URL, _ body: (CompanionOperationTransaction) throws -> T) throws -> T {
        var entered = false
        do {
            return try TekaStore(folder: folder, client: client).withCompanionTransaction(now: clock()) { transaction in
                entered = true
                return try body(transaction)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where !entered || error is TekaStore.Refused || error is TekaStore.Busy || error is ProposalStore.Unreadable {
            throw CompanionDeviceDecisionFailure.binderUnavailable
        }
    }

    /// The phone's label as the person named it, for the card; never logged.
    private func label(_ device: String) throws -> String {
        var after: String?
        for _ in 0..<1000 {
            let page = try profile.pairedDevices(now: CompanionPublishing.time(clock()), after: after)
            if let found = page.devices.first(where: { $0.deviceID == device }) { return found.label }
            guard let next = page.next else { break }
            after = next
        }
        return "your phone"
    }

    private var refuse: (CompanionDecisionRecord) throws -> Void { { _ in throw CompanionDecisionError.invalid } }
}
