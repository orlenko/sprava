import Foundation
import SpravaKit

extension CompanionProfile {
    /// companion-v0 §§9.3–9.6: check before fetching/opening a duplicate, under the device decision lock.
    public func decisionStatus(deviceID: String, requestID: String) throws -> CompanionDecisionLookup {
        guard CompanionWire.isID(deviceID), CompanionWire.isID(requestID) else { throw CompanionDecisionError.invalid }
        return try store.read { try decisionLookup(deviceID, requestID, $0) }
    }
    public func pendingDecision(deviceID: String) throws -> CompanionDecisionRecord? {
        guard CompanionWire.isID(deviceID) else { throw CompanionDecisionError.invalid }
        return try store.read { try decisionHead(deviceID, $0) }
    }
    /// Persist the complete immutable intent before any effect. A pending decision blocks every later request.
    /// The drain supplies requests in sequence order; the higher adapter authorizes and constructs `plan`.
    /// `today` is the Mac's calendar day, never the device's made_at. Replay/invalid plans are chosen here.
    public func beginDecision(_ request: CompanionAuthenticatedRequest, plan: CompanionDecisionPlan? = nil,
                              today: String, now: String) throws -> CompanionDecisionLookup {
        try reserveDecision(request, plan: plan, today: today, now: now).lookup
    }
    func reserveDecision(_ request: CompanionAuthenticatedRequest, plan: CompanionDecisionPlan? = nil,
                         today: String, now: String) throws -> DecisionReservation {
        guard CompanionWire.isID(request.deviceID), CompanionWire.isID(request.requestID), request.sequence >= 1,
              request.sequence <= JSONNumber.maxSafeInteger, CalendarDate.strict(today) != nil, CompanionOwnerRelay.time(now) else {
            throw CompanionDecisionError.invalid
        }
        return try store.write { t in
            let d = request.deviceID, r = request.requestID
            let existing = try decisionLookup(d, r, t)
            switch existing { case .none: break; default: return DecisionReservation(lookup: existing, written: false) }
            if try decisionHead(d, t) != nil { throw CompanionDecisionError.busy }
            guard let device = try record(d, t), device.state == .active, let e = try epoch(t),
                  request.epoch >= 1, request.epoch <= e else { throw CompanionDecisionError.unavailable }
            let marks = try decisionMarks(d, t)
            guard try decisionsToday(d, today, t) < 500 else { throw CompanionDecisionError.dailyCap }
            let intent: CompanionDecisionPlan
            if request.sequence <= marks.highest {
                intent = request.sequence < marks.floor ? CompanionDecisionPlan(outcome: .unknown, effect: .none) :
                    CompanionDecisionPlan(outcome: .rejected, effect: .rejection(.staleSequence))
            } else if request.action == nil { intent = CompanionDecisionPlan(outcome: .rejected, effect: .rejection(.invalid)) }
            else {
                guard let plan, plan.outcome != .unknown,
                      request.action?.kind != .note || plan.outcome == .applied else { throw CompanionDecisionError.invalid }; intent = plan
            }
            let bytes = try decisionBytes(request, plan: intent, at: now)
            try t.execute("INSERT INTO request_decisions VALUES (?, ?, ?)", .text(d), .text(r), .blob(bytes))
            return DecisionReservation(lookup: .deciding(try decodeDecision(bytes, device: d, request: r)), written: true)
        }
    }
    /// companion-v0 §9.6: after recovery proof, atomically replace only the still-matching operation intent.
    /// Reauthorize a proven-not-applied op and mint a new effect id; an uncertain op becomes a conflict card.
    /// A stale callback returns the newer intent/tombstone without changing it. It must be classified anew.
    public func recoverDecision(_ previous: CompanionDecisionRecord, recovery: CompanionDecisionRecovery,
                                now: String) throws -> CompanionDecisionLookup {
        try replaceDecision(previous, recovery: recovery, now: now).lookup
    }
    func replaceDecision(_ previous: CompanionDecisionRecord, recovery: CompanionDecisionRecovery,
                         now: String) throws -> DecisionReservation {
        guard CompanionOwnerRelay.time(now), case .operation(_, let oldID, _) = previous.plan.effect else {
            throw CompanionDecisionError.invalid
        }
        return try store.write { t in
            let d = previous.request.deviceID, r = previous.request.requestID
            if let done = try decisionTombstone(d, r, t) { return DecisionReservation(lookup: .decided(done), written: false) }
            guard let head = try decisionHead(d, t), head.request.requestID == r else { throw CompanionDecisionError.invalid }
            if head.bytes != previous.bytes { return DecisionReservation(lookup: .deciding(head), written: false) }
            guard try record(d, t)?.state == .active else { throw CompanionDecisionError.unavailable }
            let plan: CompanionDecisionPlan
            switch recovery {
            case .provenNotApplied(let authorized):
                guard authorized.outcome != .unknown else { throw CompanionDecisionError.invalid }
                if case .operation(_, let newID, _) = authorized.effect, newID == oldID { throw CompanionDecisionError.invalid }
                plan = authorized
            case .uncertain(let card): plan = CompanionDecisionPlan(outcome: .conflict, effect: .conflict(bytes: card))
            }
            let bytes = try decisionBytes(head.request, plan: plan, at: now)
            try t.execute("UPDATE request_decisions SET bytes = ? WHERE device = ?", .blob(bytes), .text(d))
            return DecisionReservation(lookup: .deciding(try decodeDecision(bytes, device: d, request: r)), written: true)
        }
    }
    /// Call only once the recorded effect is proven applied, or its idempotent capture/card creation finished.
    /// Op recovery must use companion-v0 §9.6 proof; a logged op alone is never proof of application.
    /// Completion and replay knowledge commit together. Never delete the relay request before this returns.
    @discardableResult
    public func finishDecision(_ decision: CompanionDecisionRecord, today: String, decidedAt: String) throws -> CompanionOutcomeTombstone {
        guard CalendarDate.strict(today) != nil, CompanionOwnerRelay.time(decidedAt) else { throw CompanionDecisionError.invalid }
        return try store.write { t in
            let d = decision.request.deviceID, r = decision.request.requestID
            if let tombstone = try decisionTombstone(d, r, t) { return tombstone }
            guard let head = try decisionHead(d, t), head.bytes == decision.bytes else { throw CompanionDecisionError.invalid }
            let marks = try decisionMarks(d, t), count = try decisionsToday(d, today, t)
            guard count < 500 else { throw CompanionDecisionError.dailyCap }
            guard marks.generation < JSONNumber.maxSafeInteger else { throw CompanionDecisionError.unavailable }
            try t.execute("INSERT INTO outcome_tombstones VALUES (?, ?, ?, ?, ?)", .text(d), .text(r), .integer(head.request.sequence),
                          .text(head.plan.outcome.rawValue), .text(decidedAt))
            try t.execute("UPDATE devices SET highest_seq = MAX(highest_seq, ?) WHERE device = ?", .integer(head.request.sequence), .text(d))
            try t.execute("INSERT INTO decision_daily VALUES (?, ?, ?) ON CONFLICT(device, day) DO UPDATE SET count = excluded.count",
                          .text(d), .text(today), .integer(count + 1))
            try t.execute("INSERT INTO decision_state (device, tombstone_floor, outcomes_generation) VALUES (?, ?, ?) ON CONFLICT(device) DO UPDATE SET outcomes_generation = excluded.outcomes_generation",
                          .text(d), .integer(marks.floor), .integer(marks.generation + 1))
            try t.execute("DELETE FROM request_decisions WHERE device = ?", .text(d))
            return CompanionOutcomeTombstone(deviceID: d, requestID: r, sequence: head.request.sequence, outcome: head.plan.outcome, decidedAt: decidedAt)
        }
    }
    func decisionNeedsPlan(_ request: CompanionAuthenticatedRequest) throws -> Bool {
        guard CompanionWire.isID(request.deviceID), CompanionWire.isID(request.requestID),
              request.sequence >= 1, request.sequence <= JSONNumber.maxSafeInteger else { throw CompanionDecisionError.invalid }
        return try store.read { t in
            guard request.action != nil else { return false }
            return request.sequence > (try decisionMarks(request.deviceID, t)).highest
        }
    }
    private func decisionLookup(_ d: String, _ r: String, _ t: Transaction) throws -> CompanionDecisionLookup {
        if let done = try decisionTombstone(d, r, t) { return .decided(done) }
        if let pending = try decisionHead(d, t), pending.request.requestID == r { return .deciding(pending) }
        return .none
    }
    private func decisionHead(_ d: String, _ t: Transaction) throws -> CompanionDecisionRecord? {
        let rows = try t.rows("SELECT request, bytes FROM request_decisions WHERE device = ?", .text(d))
        guard let row = rows.first else { return nil }
        guard row.count == 2, let r = row[0].text, let bytes = row[1].blob else { throw CompanionDecisionError.invalid }
        return try decodeDecision(bytes, device: d, request: r)
    }
    private func decisionTombstone(_ d: String, _ r: String, _ t: Transaction) throws -> CompanionOutcomeTombstone? {
        let rows = try t.rows("SELECT seq, outcome, decided_at FROM outcome_tombstones WHERE device = ? AND request = ?", .text(d), .text(r))
        guard let row = rows.first else { return nil }
        guard row.count == 3, let seq = row[0].integer, seq >= 1, seq <= JSONNumber.maxSafeInteger,
              let raw = row[1].text, let outcome = CompanionDecisionOutcome(rawValue: raw),
              let at = row[2].text, CompanionOwnerRelay.time(at) else { throw CompanionDecisionError.invalid }
        return CompanionOutcomeTombstone(deviceID: d, requestID: r, sequence: seq, outcome: outcome, decidedAt: at)
    }
    private func decisionMarks(_ d: String, _ t: Transaction) throws -> (highest: Int64, floor: Int64, generation: Int64) {
        guard let highest = try t.rows("SELECT highest_seq FROM devices WHERE device = ?", .text(d)).first?.first?.integer,
              highest >= 0, highest <= JSONNumber.maxSafeInteger else { throw CompanionDecisionError.invalid }
        let rows = try t.rows("SELECT tombstone_floor, outcomes_generation FROM decision_state WHERE device = ?", .text(d))
        guard let row = rows.first else { return (highest, 1, 0) }
        guard row.count == 2, let floor = row[0].integer, floor >= 1, floor <= highest + 1,
              let generation = row[1].integer, generation >= 0, generation <= JSONNumber.maxSafeInteger else { throw CompanionDecisionError.invalid }
        return (highest, floor, generation)
    }
    func decisionsToday(_ d: String, _ day: String, _ t: Transaction) throws -> Int64 {
        let rows = try t.rows("SELECT count FROM decision_daily WHERE device = ? AND day = ?", .text(d), .text(day))
        guard let row = rows.first else { return 0 }
        guard let count = row.first?.integer, count >= 0, count <= 500 else { throw CompanionDecisionError.invalid }; return count
    }
}
