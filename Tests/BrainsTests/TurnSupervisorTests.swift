import Testing
@testable import Brains

private func agentSupervisor() throws -> TurnSupervisorPolicy {
    TurnSupervisorPolicy(limits: try .agent(terminationGrace: .seconds(5)))
}

@Test func activityCannotExtendTheOverallDeadlineOrReviveAnExpiredTurn() throws {
    var supervisor = try agentSupervisor()
    for second in stride(from: 100, through: 800, by: 100) { #expect(supervisor.event(at: .seconds(second)).isEmpty) }
    #expect(supervisor.event(at: .seconds(850)).isEmpty)
    #expect(supervisor.tick(at: .seconds(899)).isEmpty)
    #expect(supervisor.event(at: .seconds(900)) == [.interrupt])
    #expect(supervisor.stopCause == .overall)
    supervisor.turnFinished(at: .seconds(901), succeeded: true)
    #expect(supervisor.outcome == .failed(.overall))

    var idle = try agentSupervisor()
    #expect(idle.event(at: .seconds(120)) == [.interrupt])
    #expect(idle.stopCause == .inactivity)
    idle.turnFinished(at: .seconds(121), succeeded: true)
    #expect(idle.outcome == .failed(.inactivity))
}

@Test func stopEscalatesOnceAndHoldsTheSessionUntilConfirmedProcessExit() throws {
    var supervisor = try agentSupervisor()
    #expect(supervisor.stop(at: .seconds(10)) == [.interrupt])
    #expect(supervisor.stop(at: .seconds(12)).isEmpty)
    #expect(supervisor.tick(at: .seconds(15)) == [.terminate])
    #expect(supervisor.needsRestart)
    supervisor.turnFinished(at: .seconds(16), succeeded: true) // A late result does not prove the process exited.
    #expect(supervisor.phase == .terminating && supervisor.outcome == nil)
    #expect(supervisor.stop(at: .seconds(19)).isEmpty)
    #expect(supervisor.tick(at: .seconds(20)) == [.kill])
    #expect(supervisor.tick(at: .seconds(2000)).isEmpty)
    supervisor.turnFinished(at: .seconds(2001), succeeded: true)
    #expect(supervisor.phase == .killing && supervisor.outcome == nil)
    supervisor.processExited(at: .seconds(2002))
    #expect(supervisor.phase == .finished && supervisor.outcome == .interrupted)
    #expect(supervisor.tick(at: .seconds(2003)).isEmpty)
}

@Test func completionDuringInterruptSuppressesEscalationButNeverErasesATimeout() throws {
    var stopped = try agentSupervisor()
    _ = stopped.stop(at: .seconds(10)); stopped.turnFinished(at: .seconds(13), succeeded: true)
    #expect(stopped.outcome == .interrupted && !stopped.needsRestart)
    #expect(stopped.tick(at: .seconds(30)).isEmpty)
    var expired = try agentSupervisor()
    _ = expired.tick(at: .seconds(120)); expired.processExited(at: .seconds(121))
    #expect(expired.outcome == .failed(.inactivity) && expired.needsRestart)
    var completed = try agentSupervisor(); completed.turnFinished(at: .seconds(1), succeeded: true)
    #expect(completed.outcome == .replied)
    var crashed = try agentSupervisor(); crashed.processExited(at: .seconds(1))
    #expect(crashed.outcome == .failed(.engineExited) && crashed.needsRestart)
}

@Test func aBadClockFailsClosedAndCoarseTicksNeverSendSeveralEscalationsAtOnce() throws {
    var supervisor = try agentSupervisor()
    #expect(supervisor.event(at: .seconds(100)).isEmpty)
    #expect(supervisor.tick(at: .seconds(99)) == [.interrupt])
    #expect(supervisor.stopCause == .invalidClock)
    #expect(supervisor.tick(at: .seconds(98)).isEmpty)
    #expect(supervisor.tick(at: .seconds(2000)) == [.terminate])
    #expect(supervisor.tick(at: .seconds(2000)).isEmpty)
    #expect(supervisor.tick(at: .seconds(2005)) == [.kill])
    supervisor.processExited(at: .seconds(2006))
    #expect(supervisor.outcome == .failed(.invalidClock))
}

@Test func localInactivityAndInvalidLimitsAreExplicitWithoutInventingALocalOverallDefault() throws {
    var local = TurnSupervisorPolicy(limits: try TurnSupervisorLimits(inactivity: .seconds(30), overall: .seconds(90), terminationGrace: .seconds(2)))
    #expect(local.tick(at: .seconds(29)).isEmpty)
    #expect(local.tick(at: .seconds(30)) == [.interrupt])
    #expect(local.stopCause == .inactivity)
    #expect(throws: TurnSupervisorError.invalidLimits) {
        try TurnSupervisorLimits(inactivity: .zero, overall: .seconds(90), terminationGrace: .seconds(2))
    }
}
