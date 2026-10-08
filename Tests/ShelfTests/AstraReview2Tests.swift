import Darwin
import Foundation
@testable import Shelf
import Testing

/// Regressions from the second adversarial review of increment 1 (hub titles under the privacy ratchet, the backup
/// queue, intake cards whose digest was not kept, concurrent Shelf changes, revocation on the command queue).
/// Invented data only.
@Suite(.serialized) struct AstraReview2Tests {
    func temp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra2-\(label)-\(UUID().uuidString)")
    }

    // MARK: - 5. Concurrent Shelf changes never lose a binder

    @Test func concurrentShelfAddsAreNeverLost() throws {
        let support = temp("support")
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            try? ShelfStore(supportDirectory: support).add(URL(fileURLWithPath: "/Invented/binder-\(i)", isDirectory: true))
        }
        #expect(try ShelfStore(supportDirectory: support).readFolders().count == 64)
        DispatchQueue.concurrentPerform(iterations: 32) { i in
            try? ShelfStore(supportDirectory: support).remove(URL(fileURLWithPath: "/Invented/binder-\(i * 2)", isDirectory: true))
        }
        let left = try ShelfStore(supportDirectory: support).readFolders().map(\.lastPathComponent)
        #expect(left.count == 32 && left.allSatisfy { Int($0.dropFirst("binder-".count))! % 2 == 1 }, "\(left)")
    }
}
