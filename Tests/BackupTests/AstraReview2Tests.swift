@testable import Backup
import Darwin
import Foundation
import SpravaKit
import Testing

/// Regressions from the second adversarial review of increment 1 (hub titles under the privacy ratchet, the backup
/// queue, intake cards whose digest was not kept, concurrent Shelf changes, revocation on the command queue).
/// Invented data only.
@Suite(.serialized) struct AstraReview2Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func temp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra2-\(label)-\(UUID().uuidString)")
    }

    // MARK: - 2. A waiting offload never starves the other requests

    @Test func waitingOffloadsTakeTurnsAndQueuedRequestsGoFirst() throws {
        let requests = BackupRequests(support: temp("support"))
        let earlier = ISOTime.string(now), later = ISOTime.string(now.addingTimeInterval(60))
        try requests.enqueue(.init(id: "a", kind: "offload", binder: "/Invented/a", at: earlier))
        try requests.enqueue(.init(id: "b", kind: "offload", binder: "/Invented/b", at: later))
        requests.update("a") { $0.state = "waiting_for_icloud" }
        requests.update("b") { $0.state = "waiting_for_icloud" }
        #expect(try requests.next()?.id == "a")
        // Retried and still waiting: its time moves on, so the other one comes next.
        requests.update("a") { $0.at = ISOTime.string(self.now.addingTimeInterval(120)) }
        #expect(try requests.next()?.id == "b")
        try requests.enqueue(.init(id: "c", kind: "drill", binder: "/Invented/c", at: later))
        #expect(try requests.next()?.id == "c")
    }
}
