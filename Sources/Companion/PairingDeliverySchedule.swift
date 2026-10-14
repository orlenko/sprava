import Foundation
import SpravaKit

struct PairingDeliverySchedule {
    let next: String?
    let attempts: Int64
    let keysUploaded: Bool
    let wrappedUploaded: Bool
    let blocked: Int?
}
extension CompanionProfile {
    func deliverySchedule(_ id: String, _ t: Transaction) throws -> PairingDeliverySchedule {
        guard try record(id, t)?.state == .active,
              let r = try t.rows("SELECT delivery_next, delivery_attempts, keys_uploaded, wrapped_uploaded, delivery_blocked " +
                                "FROM pairings WHERE device = ?", .text(id)).first,
              r.count == 5, let attempts = r[1].integer, (0...5).contains(attempts),
              let keys = r[2].integer, (0...1).contains(keys), let wrapped = r[3].integer, (0...1).contains(wrapped),
              r[0] == .null || r[0].text.map(CompanionOwnerRelay.time) == true,
              r[4] == .null || r[4].integer == 409 || r[4].integer == 410 else { throw CompanionCredentialError.invalid }
        return PairingDeliverySchedule(next: r[0].text, attempts: attempts, keysUploaded: keys == 1,
                                       wrappedUploaded: wrapped == 1, blocked: r[4].integer.map(Int.init))
    }
    func reserveDeliveryAttempt(_ id: String, now: String) throws -> (send: Bool, retryAt: String, schedule: PairingDeliverySchedule) {
        guard CompanionOwnerRelay.time(now), let date = Timestamp.parse(now) else { throw CompanionOwnerPairingError.invalid }
        return try store.write { t in
            let deadline = try pairingDeadline(id, t), schedule = try deliverySchedule(id, t)
            guard now < deadline else { throw CompanionOwnerPairingError.expired }
            if let next = schedule.next, now < next { return (false, next, schedule) }
            let delays: [Double] = [2, 4, 8, 16, 30, 30]
            let next = min(date.addingTimeInterval(delays[Int(schedule.attempts)]).ISO8601Format(), deadline)
            try t.execute("UPDATE pairings SET delivery_next = ?, delivery_attempts = ? WHERE device = ?",
                          .text(next), .integer(min(schedule.attempts + 1, 5)), .text(id))
            return (true, next, schedule)
        }
    }
    func recordDeliveryUpload(_ id: String, wrapped: Bool) throws {
        try store.write { t in
            let schedule = try deliverySchedule(id, t)
            if wrapped {
                guard schedule.keysUploaded else { throw CompanionOwnerPairingError.invalid }
                try t.execute("UPDATE pairings SET wrapped_uploaded = 1 WHERE device = ?", .text(id))
            } else { try t.execute("UPDATE pairings SET keys_uploaded = 1 WHERE device = ?", .text(id)) }
        }
    }
    func blockDelivery(_ id: String, status: Int) throws {
        guard status == 409 || status == 410 else { throw CompanionOwnerPairingError.invalid }
        try store.write { t in
            _ = try deliverySchedule(id, t)
            try t.execute("UPDATE pairings SET delivery_blocked = ? WHERE device = ?", .integer(Int64(status)), .text(id))
        }
    }
    func paceAcknowledgmentPoll(_ id: String, now: String) throws -> String {
        guard CompanionOwnerRelay.time(now), let date = Timestamp.parse(now) else { throw CompanionOwnerPairingError.invalid }
        return try store.write { t in
            let schedule = try deliverySchedule(id, t), deadline = try pairingDeadline(id, t)
            guard schedule.keysUploaded, schedule.wrappedUploaded else { throw CompanionOwnerPairingError.invalid }
            let next = min(date.addingTimeInterval(2).ISO8601Format(), deadline)
            try t.execute("UPDATE pairings SET delivery_next = ?, delivery_attempts = 0 WHERE device = ?", .text(next), .text(id))
            return next
        }
    }
}
