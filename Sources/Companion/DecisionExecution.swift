import Foundation
import SpravaKit

/// An operation's proof is supplied only after settling its binder under the write lock (§9.6).
/// Captures and cards instead use their recorded identities for idempotent creation.
public enum CompanionDecisionProof: Sendable {
    case applied
    case notApplied(CompanionDecisionPlan)
    case uncertain(conflict: Data)
    case idempotent
}
/// The adapter keeps its binder/effect lock for the entire callback, through authorization and commit.
/// `apply` writes only the callback's exact recorded effect; preparing must never apply an effect.
/// Recovery prepares any replacement/new effect id under that same lock, without applying it first.
public protocol CompanionDecisionAdapter {
    func withPreparedDecision<Result>(for request: CompanionAuthenticatedRequest,
        _ body: (CompanionDecisionPlan, (CompanionDecisionRecord) throws -> Void) throws -> Result) throws -> Result
    func withRecoveredDecision<Result>(for record: CompanionDecisionRecord,
        _ body: (CompanionDecisionProof, (CompanionDecisionRecord) throws -> Void) throws -> Result) throws -> Result
}
public struct CompanionExecutedDecision: Sendable {
    public let outcome: CompanionOutcomeTombstone
    /// False for a request already committed before this call; never count it toward progress again.
    public let committed: Bool
}
struct DecisionReservation: Sendable {
    let lookup: CompanionDecisionLookup
    let written: Bool
}

/// companion-v0 §§9.4–9.6: durable intent before effects, exact-record recovery, then outcome commit.
/// Caller holds the device decision lock throughout. Relay deletion happens only after this returns.
/// The higher drain checks owner admission before invoking this executor.
public struct CompanionDecisionExecution: Sendable {
    private let profile: CompanionProfile
    public init(profile: CompanionProfile) { self.profile = profile }

    public func decide(_ request: CompanionAuthenticatedRequest, today: String, now: String,
                       adapter: any CompanionDecisionAdapter) throws -> CompanionExecutedDecision {
        try validate(today, now)
        switch try profile.decisionStatus(deviceID: request.deviceID, requestID: request.requestID) {
        case .decided(let outcome): return CompanionExecutedDecision(outcome: outcome, committed: false)
        case .deciding(let record): return try recover(record, today: today, now: now, adapter: adapter)
        case .none: break
        }
        guard try profile.pendingDecision(deviceID: request.deviceID) == nil else { throw CompanionDecisionError.busy }
        if try !profile.decisionNeedsPlan(request) {
            return try finishReservation(profile.reserveDecision(request, today: today, now: now),
                                         today: today, now: now, apply: { _ in throw CompanionDecisionError.invalid })
        }
        return try adapter.withPreparedDecision(for: request) { plan, apply in
            try finishReservation(profile.reserveDecision(request, plan: plan, today: today, now: now),
                                  today: today, now: now, apply: apply)
        }
    }
    /// Run before collecting this device's next requests. A failed recovery leaves the intent in place.
    public func recoverPending(deviceID: String, today: String, now: String,
                               adapter: any CompanionDecisionAdapter) throws -> CompanionExecutedDecision? {
        try validate(today, now)
        guard let record = try profile.pendingDecision(deviceID: deviceID) else { return nil }
        return try recover(record, today: today, now: now, adapter: adapter)
    }
    private func recover(_ record: CompanionDecisionRecord, today: String, now: String,
                         adapter: any CompanionDecisionAdapter) throws -> CompanionExecutedDecision {
        switch record.plan.effect {
        case .none, .rejection: return try commit(record, today: today, now: now)
        default: break
        }
        return try adapter.withRecoveredDecision(for: record) { proof, apply in
            switch (record.plan.effect, proof) {
            case (.operation, .applied): return try commit(record, today: today, now: now)
            case (.operation, .notApplied(let plan)):
                return try finishReservation(profile.replaceDecision(record, recovery: .provenNotApplied(plan), now: now),
                                             today: today, now: now, apply: apply)
            case (.operation, .uncertain(let card)):
                return try finishReservation(profile.replaceDecision(record, recovery: .uncertain(conflict: card), now: now),
                                             today: today, now: now, apply: apply)
            case (.capture, .idempotent), (.conflict, .idempotent):
                try apply(record); return try commit(record, today: today, now: now)
            default: throw CompanionDecisionError.invalid
            }
        }
    }
    private func finishReservation(_ reservation: DecisionReservation, today: String, now: String,
                                   apply: (CompanionDecisionRecord) throws -> Void) throws -> CompanionExecutedDecision {
        switch reservation.lookup {
        case .decided(let outcome): return CompanionExecutedDecision(outcome: outcome, committed: false)
        case .none: throw CompanionDecisionError.invalid
        case .deciding(let record):
            // Another reservation or stale recovery result must be classified anew, never applied with this adapter.
            guard reservation.written else { throw CompanionDecisionError.busy }
            switch record.plan.effect { case .none, .rejection: break; default: try apply(record) }
            return try commit(record, today: today, now: now)
        }
    }
    private func commit(_ record: CompanionDecisionRecord, today: String, now: String) throws -> CompanionExecutedDecision {
        CompanionExecutedDecision(outcome: try profile.finishDecision(record, today: today, decidedAt: now), committed: true)
    }
    private func validate(_ today: String, _ now: String) throws {
        guard CalendarDate.strict(today) != nil, CompanionOwnerRelay.time(now) else { throw CompanionDecisionError.invalid }
    }
}
