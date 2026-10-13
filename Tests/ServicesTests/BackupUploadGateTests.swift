import Backup
import Foundation
@testable import Services
import Testing

@Suite struct BackupUploadGateTests {
    @Test(.enabled(if: Restic.locate() != nil)) func setupRefusesAnUnfinishedLocationCheck() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-setup-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let repository = support.appendingPathComponent("mirror"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let original = Backup(support: support, key: "INVENTED-KEY", uploadCheck: { _ in release.wait(); return .notInICloud })
        let backup = BackupUploadGate.bounded(original, patience: 0.02)
        #expect(throws: Backup.Failure.self) { try backup.setUp(primary: repository, iCloudKeychain: false) }
        #expect(try backup.settings().primary == nil)
        release.signal()
        #expect(BackupUploadGate.of(repository).ended.wait(timeout: .now() + 5) == .success)
    }

    @Test func aStalledGateReturnsAndNeverUsesItsLateResultAsFreshProof() {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-upload-gate-\(UUID().uuidString)")
        let gate = BackupUploadGate.of(repository)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let result = gate.check(repository, scan: { _ in entered.signal(); release.wait(); return .uploaded }, patience: 0.02)
        #expect(result == .notChecked)
        #expect(entered.wait(timeout: .now() + 5) == .success)
        // A later caller cannot start another stalled worker or accept its incomplete result.
        #expect(gate.check(repository, scan: { _ in Issue.record("a second scan started while stalled"); return .uploaded },
                           patience: 0.02) == .notChecked)
        release.signal()
        #expect(gate.ended.wait(timeout: .now() + 5) == .success)
        // Its late uploaded result is discarded: this check must use the current waiting result.
        #expect(gate.check(repository, scan: { _ in .waiting(4) }, patience: 5) == .waiting(4))
    }
}
