import Foundation
import SpravaKit

extension CompanionProfile {
    func startPairingSchedule(_ id: String, now: String) throws {
        guard CompanionOwnerRelay.time(now), let date = Timestamp.parse(now) else { throw CompanionOwnerPairingError.invalid }
        let deadline = date.addingTimeInterval(600).ISO8601Format()
        try store.write { t in
            guard let r = try record(id, t), r.state == .pairing, !r.creationAttempted else { throw CompanionOwnerPairingError.invalid }
            try t.execute("UPDATE devices SET local_deadline = ?, next_poll = ? WHERE device = ? AND local_deadline IS NULL",
                          .text(deadline), .text(now), .text(id))
        }
    }
    func boundPairingSchedule(_ id: String, expires: String) throws {
        guard CompanionOwnerRelay.time(expires) else { throw CompanionOwnerPairingError.invalid }
        try store.write { t in
            let deadline = try pairingDeadline(id, t)
            if expires < deadline { try t.execute("UPDATE devices SET local_deadline = ? WHERE device = ?", .text(expires), .text(id)) }
        }
    }
    func pairingDeadline(_ id: String, _ t: Transaction) throws -> String {
        guard CompanionWire.isID(id), let r = try record(id, t), r.state == .pairing || r.state == .active,
              let deadline = try t.rows("SELECT local_deadline FROM devices WHERE device = ?", .text(id)).first?.first?.text,
              CompanionOwnerRelay.time(deadline) else { throw CompanionOwnerPairingError.invalid }
        return deadline
    }
    func checkPairingLifetime(_ id: String, now: String) throws -> String {
        guard CompanionOwnerRelay.time(now) else { throw CompanionOwnerPairingError.invalid }
        let deadline = try store.read { try pairingDeadline(id, $0) }
        if now >= deadline {
            let state = try store.read { try record(id, $0)?.state }
            if state == .pairing { try abandonPairing(deviceID: id) }
            else if state == .active { try finishPairingSecrets(deviceID: id) }
            throw CompanionOwnerPairingError.expired
        }
        return deadline
    }
    // Reserve a poll slot durably before GET; restarts cannot make it a tight polling loop.
    func reservePairingPoll(_ id: String, now: String) throws -> (send: Bool, retryAt: String) {
        guard CompanionOwnerRelay.time(now), let date = Timestamp.parse(now) else { throw CompanionOwnerPairingError.invalid }
        return try store.write { t in
            let deadline = try pairingDeadline(id, t)
            guard now < deadline, try record(id, t)?.state == .pairing,
                  let next = try t.rows("SELECT next_poll FROM devices WHERE device = ?", .text(id)).first?.first?.text,
                  CompanionOwnerRelay.time(next) else { throw CompanionOwnerPairingError.invalid }
            if now < next { return (false, next) }
            let retryAt = min(date.addingTimeInterval(2).ISO8601Format(), deadline)
            try t.execute("UPDATE devices SET next_poll = ? WHERE device = ?", .text(retryAt), .text(id))
            return (true, retryAt)
        }
    }
}
