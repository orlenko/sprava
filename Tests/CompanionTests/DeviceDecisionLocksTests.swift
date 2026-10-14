import Foundation
import Testing
@testable import Companion

private func lockID(_ byte: UInt8) -> String { CompanionWire.base64(Data(repeating: byte, count: 16)) }
private enum LockFixtureError: Error { case failed }
private actor LockGate {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func waitInside() async {
        await withCheckedContinuation { continuation in
            release = continuation; entered = true
            observer?.resume(); observer = nil
        }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func open() { release?.resume(); release = nil }
}

@Test func aDeviceLockCoversNetworkAwaitsWhileOtherDevicesCanProceed() async throws {
    let locks = CompanionDeviceDecisionLocks(), gate = LockGate()
    let pending = Task { try await locks.withLock(deviceID: lockID(1)) { await gate.waitInside(); return 7 } }
    await gate.waitForEntry()
    await #expect(throws: CompanionOwnerConnectionError.busy) {
        try await locks.withLock(deviceID: lockID(1)) { Issue.record("Contending callback ran") }
    }
    let other = try await locks.withLock(deviceID: lockID(2)) { 11 }
    #expect(other == 11)
    await gate.open()
    #expect(try await pending.value == 7)
    #expect(try await locks.withLock(deviceID: lockID(1)) { 13 } == 13)
}

@Test func thrownAndCancelledOperationsReleaseTheDeviceLock() async throws {
    let locks = CompanionDeviceDecisionLocks()
    await #expect(throws: LockFixtureError.self) {
        try await locks.withLock(deviceID: lockID(3)) { throw LockFixtureError.failed }
    }
    let gate = LockGate()
    let cancelled = Task {
        try await locks.withLock(deviceID: lockID(3)) {
            await gate.waitInside(); try Task.checkCancellation()
        }
    }
    await gate.waitForEntry(); cancelled.cancel(); await gate.open()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try await locks.withLock(deviceID: lockID(3)) { true })
}

@Test func invalidIDsAndAlreadyCancelledTasksNeverEnterTheCallback() async throws {
    let locks = CompanionDeviceDecisionLocks()
    for id in ["", "../credentials", lockID(4) + "="] {
        await #expect(throws: CompanionRelayError.invalid) {
            try await locks.withLock(deviceID: id) { Issue.record("Invalid callback ran") }
        }
    }
    let gate = LockGate()
    let cancelled = Task {
        await gate.waitInside()
        try await locks.withLock(deviceID: lockID(4)) { Issue.record("Cancelled callback ran") }
    }
    await gate.waitForEntry(); cancelled.cancel(); await gate.open()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try await locks.withLock(deviceID: lockID(4)) { true })
}

@Test func concurrentDeviceLocksAreBoundedAndAReleasedSlotCanBeReused() async throws {
    let locks = CompanionDeviceDecisionLocks()
    let gates = (1...20).map { _ in LockGate() }
    let tasks = gates.enumerated().map { index, gate in
        Task { try await locks.withLock(deviceID: lockID(UInt8(index + 1))) { await gate.waitInside() } }
    }
    for gate in gates { await gate.waitForEntry() }
    await #expect(throws: CompanionOwnerConnectionError.busy) {
        try await locks.withLock(deviceID: lockID(21)) { Issue.record("Over-limit callback ran") }
    }
    await gates[0].open(); try await tasks[0].value
    #expect(try await locks.withLock(deviceID: lockID(21)) { true })
    for gate in gates.dropFirst() { await gate.open() }
    for task in tasks.dropFirst() { try await task.value }
}
