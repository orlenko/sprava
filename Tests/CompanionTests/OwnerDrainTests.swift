import Foundation
import Testing
@testable import Companion

private let orchestrationDevices = (1...5).map { CompanionWire.base64(Data(repeating: UInt8($0), count: 16)) }
    .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
private let orchestrationNow = "2026-10-15T12:00:00Z"
private enum DrainFixtureError: Error, Equatable { case transport, publication }
private actor DrainVisits {
    var turns: [String] = []
    var published: [String] = []
    var allowances: [Int] = []
    func visit(_ device: String, _ allowance: CompanionCollectionAllowance) {
        turns.append(device); allowances.append(allowance.fetches)
    }
    func publish(_ device: String) { published.append(device) }
}

@Test func drainSharesOneGlobalBudgetAndTheNextDrainReachesTheDeviceThatWaited() async throws {
    let drain = CompanionOwnerDrain(), visits = DrainVisits()
    let work: @Sendable (String, CompanionCollectionAllowance) async throws -> CompanionDeviceDrainTurn = { d, allowance in
        await visits.visit(d, allowance)
        return CompanionDeviceDrainTurn(downloadedBytes: 2097152, fetches: 25, checkedRequests: 25, decisionsCommitted: 25)
    }
    let first = try await drain.drain(activeDevices: Array(orchestrationDevices.reversed()), now: { orchestrationNow },
        turn: work, publishOutcomes: { await visits.publish($0) })
    #expect(first.visitedDevices == Array(orchestrationDevices.prefix(4)))
    #expect(first.downloadedBytes == 8388608 && first.fetches == 100 && first.checkedRequests == 100 && first.decisionsCommitted == 100)
    #expect(await visits.allowances == [100, 75, 50, 25])
    #expect(await visits.published == orchestrationDevices)
    let second = try await drain.drain(activeDevices: orchestrationDevices, now: { orchestrationNow },
        turn: work, publishOutcomes: { _ in })
    #expect(second.visitedDevices == Array(orchestrationDevices.dropFirst()))
}

@Test func retryableDeviceFailureDoesNotHoldOtherDevicesAndItsDirtyOutcomesStillPublish() async throws {
    let drain = CompanionOwnerDrain(), visits = DrainVisits(), blocked = orchestrationDevices[0]
    let first = try await drain.drain(activeDevices: orchestrationDevices, now: { orchestrationNow }, turn: { d, allowance in
        await visits.visit(d, allowance)
        return CompanionDeviceDrainTurn(checkedRequests: 1, decisionsCommitted: d == blocked ? 0 : 1, needsRetry: d == blocked)
    }, publishOutcomes: { await visits.publish($0) })
    #expect(first.visitedDevices == orchestrationDevices && first.decisionsCommitted == 4)
    let second = try await drain.drain(activeDevices: orchestrationDevices, now: { "2026-10-15T12:00:59Z" },
        turn: { _, _ in CompanionDeviceDrainTurn() }, publishOutcomes: { await visits.publish($0) })
    #expect(second.visitedDevices == Array(orchestrationDevices.dropFirst()))
    #expect(await visits.published == orchestrationDevices + orchestrationDevices)
}

@Test func jobFailureStopsDeviceTurnsButStillAttemptsEveryOutcomeAndPreservesTheFirstError() async throws {
    let drain = CompanionOwnerDrain(), visits = DrainVisits()
    await #expect(throws: DrainFixtureError.transport) {
        try await drain.drain(activeDevices: orchestrationDevices, now: { orchestrationNow }, turn: { d, allowance in
            await visits.visit(d, allowance)
            if d == orchestrationDevices[1] { throw DrainFixtureError.transport }
            return CompanionDeviceDrainTurn(decisionsCommitted: 1)
        }, publishOutcomes: { d in
            await visits.publish(d)
            if d == orchestrationDevices[0] { throw DrainFixtureError.publication }
        })
    }
    #expect(await visits.turns == Array(orchestrationDevices.prefix(2)))
    #expect(await visits.published == orchestrationDevices)
}

@Test func invalidAdapterCostsCannotOverflowOrAllowAnotherTurnAndOutcomesAreStillAttempted() async throws {
    let bad = [CompanionDeviceDrainTurn(downloadedBytes: Int.max), CompanionDeviceDrainTurn(fetches: -1),
               CompanionDeviceDrainTurn(fetches: 26), CompanionDeviceDrainTurn(checkedRequests: 26),
               CompanionDeviceDrainTurn(decisionsCommitted: 501)]
    for result in bad {
        let drain = CompanionOwnerDrain(), visits = DrainVisits()
        await #expect(throws: CompanionRelayError.invalid) {
            try await drain.drain(activeDevices: orchestrationDevices, now: { orchestrationNow }, turn: { d, allowance in
                await visits.visit(d, allowance); return result
            }, publishOutcomes: { await visits.publish($0) })
        }
        #expect(await visits.turns.count == 1)
        #expect(await visits.published == orchestrationDevices)
    }
}

private actor DrainPause {
    private var started = false
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true; entered?.resume(); entered = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { entered = $0 }
    }
    func resume() { release?.resume(); release = nil }
}
@Test func overlappingDrainsAreRefusedWhileAnAdapterIsSuspended() async throws {
    let drain = CompanionOwnerDrain(), pause = DrainPause()
    let first = Task {
        try await drain.drain(activeDevices: [orchestrationDevices[0]], now: { orchestrationNow },
            turn: { _, _ in await pause.pause(); return CompanionDeviceDrainTurn() }, publishOutcomes: { _ in })
    }
    await pause.waitUntilStarted()
    await #expect(throws: CompanionOwnerConnectionError.busy) {
        try await drain.drain(activeDevices: [], now: { orchestrationNow },
            turn: { _, _ in CompanionDeviceDrainTurn() }, publishOutcomes: { _ in })
    }
    await pause.resume()
    #expect(try await first.value.visitedDevices == [orchestrationDevices[0]])
}
