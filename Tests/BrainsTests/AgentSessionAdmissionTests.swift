import Foundation
import Testing
@testable import Brains

private func reserved(_ value: AgentSessionAdmission.Admission) throws -> AgentSessionAdmission.Lease {
    guard case .reserved(let lease) = value else { throw AdmissionTestFailure.notReserved }
    return lease
}
private enum AdmissionTestFailure: Error { case notReserved }

@Test func concurrentReservationsCountStartingProcessesAndSeparateTaskCapacity() async throws {
    let admission = try AgentSessionAdmission(conversationLimit: 3, taskLimit: 2)
    let leases = await withTaskGroup(of: AgentSessionAdmission.Lease?.self) { group in
        for _ in 0..<40 {
            group.addTask {
                if case .reserved(let lease) = await admission.reserve(sessionID: UUID(), kind: .conversation) { return lease }
                return nil
            }
        }
        var result: [AgentSessionAdmission.Lease] = []
        for await lease in group { if let lease { result.append(lease) } }
        return result
    }
    #expect(leases.count == 3)
    let full = await admission.reserve(sessionID: UUID(), kind: .conversation)
    #expect(full == .capacity(idleCandidate: nil))
    let task = try reserved(await admission.reserve(sessionID: UUID(), kind: .task))
    let duplicate = await admission.reserve(sessionID: task.sessionID, kind: .conversation)
    #expect(duplicate == .occupied)
    _ = try reserved(await admission.reserve(sessionID: UUID(), kind: .task))
    let tasksFull = await admission.reserve(sessionID: UUID(), kind: .task)
    #expect(tasksFull == .capacity(idleCandidate: nil))
}

@Test func retirementKeepsTheSessionAndProcessSlotUntilConfirmedExit() async throws {
    let admission = try AgentSessionAdmission(conversationLimit: 1, taskLimit: 1)
    let session = UUID()
    let lease = try reserved(await admission.reserve(sessionID: session, kind: .conversation))
    #expect(await admission.started(lease))
    #expect(await admission.beginTurn(lease))
    #expect(await admission.stop(lease))
    #expect(await admission.stop(lease) == false)
    #expect(await admission.finishedTurn(lease) == false)
    #expect(await admission.started(lease) == false)
    #expect(await admission.beginTurn(lease) == false)
    let duplicate = await admission.reserve(sessionID: session, kind: .conversation)
    let full = await admission.reserve(sessionID: UUID(), kind: .conversation)
    #expect(duplicate == .occupied)
    #expect(full == .capacity(idleCandidate: nil))
    #expect(await admission.confirmedExit(lease))
    let replacement = try reserved(await admission.reserve(sessionID: session, kind: .conversation))
    #expect(replacement != lease)
    #expect(await admission.confirmedExit(lease) == false)
    #expect(await admission.stop(lease) == false)
    #expect(await admission.started(replacement))
    #expect(await admission.beginTurn(replacement))
}

@Test func evictionChoosesOldestIdleAndRechecksItBeforeStopping() async throws {
    let admission = try AgentSessionAdmission(conversationLimit: 2, taskLimit: 1)
    let first = try reserved(await admission.reserve(sessionID: UUID(), kind: .conversation))
    let second = try reserved(await admission.reserve(sessionID: UUID(), kind: .conversation))
    #expect(await admission.started(first))
    #expect(await admission.started(second))
    var full = await admission.reserve(sessionID: UUID(), kind: .conversation)
    #expect(full == .capacity(idleCandidate: first))
    #expect(await admission.beginTurn(first))
    #expect(await admission.retireIdle(first) == false)
    #expect(await admission.finishedTurn(first))
    full = await admission.reserve(sessionID: UUID(), kind: .conversation)
    #expect(full == .capacity(idleCandidate: second))
    #expect(await admission.retireIdle(second))
    #expect(await admission.retireIdle(second) == false)
    #expect(await admission.beginTurn(second) == false)
    #expect(await admission.confirmedExit(second))
    _ = try reserved(await admission.reserve(sessionID: UUID(), kind: .conversation))
}

@Test func failedStartsAndStoppedStartsRemainClosedUntilOwnerConfirmsNoProcess() async throws {
    #expect(throws: AgentSessionAdmission.Failure.invalidLimits) {
        _ = try AgentSessionAdmission(conversationLimit: 0, taskLimit: 1)
    }
    let admission = try AgentSessionAdmission(conversationLimit: 1, taskLimit: 1)
    let lease = try reserved(await admission.reserve(sessionID: UUID(), kind: .task))
    #expect(await admission.beginTurn(lease) == false)
    #expect(await admission.stop(lease))
    #expect(await admission.started(lease) == false)
    let full = await admission.reserve(sessionID: UUID(), kind: .task)
    #expect(full == .capacity(idleCandidate: nil))
    #expect(await admission.confirmedExit(lease))
    _ = try reserved(await admission.reserve(sessionID: UUID(), kind: .task))
}
