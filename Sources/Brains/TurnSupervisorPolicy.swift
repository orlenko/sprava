import Foundation

public enum TurnSupervisorError: Error, Sendable { case invalidLimits }
public struct TurnSupervisorLimits: Sendable {
    public let inactivity: Duration
    public let overall: Duration
    public let interruptGrace: Duration
    public let terminationGrace: Duration
    /// conversation §11 fixes the interrupt grace at 5s. The adapter explicitly chooses the post-TERM grace.
    public init(inactivity: Duration, overall: Duration, terminationGrace: Duration) throws {
        guard inactivity > .zero, overall > .zero, terminationGrace > .zero else {
            throw TurnSupervisorError.invalidLimits
        }
        self.inactivity = inactivity; self.overall = overall
        self.interruptGrace = .seconds(5); self.terminationGrace = terminationGrace
    }
    public static func agent(terminationGrace: Duration) throws -> Self {
        try Self(inactivity: .seconds(120), overall: .seconds(900), terminationGrace: terminationGrace)
    }
}

/// conversation §11: engine-independent deadlines and Stop escalation, with no clocks, processes or I/O.
/// Feed monotonic elapsed time since this turn began; an event arriving at/after a deadline cannot revive it.
/// Intents do not prove a process died. After TERM/KILL, a late result never releases the session barrier;
/// processExited must confirm exit before another driver can resume that session.
public struct TurnSupervisorPolicy: Sendable {
    public enum Phase: Sendable { case running, interrupting, terminating, killing, finished }
    public enum Intent: Sendable, Equatable { case interrupt, terminate, kill }
    public enum StopCause: Sendable, Equatable { case person, inactivity, overall, invalidClock }
    public enum Failure: Sendable, Equatable { case inactivity, overall, invalidClock, engineExited }
    public enum Outcome: Sendable, Equatable { case replied, interrupted, failed(Failure) }
    public private(set) var phase: Phase = .running
    public private(set) var stopCause: StopCause?
    public private(set) var outcome: Outcome?
    public private(set) var needsRestart = false
    private let limits: TurnSupervisorLimits
    private var clock: Duration = .zero
    private var lastEvent: Duration = .zero
    private var signalledAt: Duration = .zero
    public init(limits: TurnSupervisorLimits) { self.limits = limits }

    public mutating func tick(at elapsed: Duration) -> [Intent] { advance(at: elapsed, event: false) }
    public mutating func event(at elapsed: Duration) -> [Intent] { advance(at: elapsed, event: true) }
    public mutating func stop(at elapsed: Duration) -> [Intent] {
        let intents = advance(at: elapsed, event: false)
        guard phase == .running else { return intents }
        return beginStop(.person)
    }
    /// A structured result ends the turn only while the engine remains reusable (before TERM).
    public mutating func turnFinished(at elapsed: Duration, succeeded: Bool) {
        guard phase != .finished, phase != .terminating, phase != .killing else { return }
        recordCompletionClock(elapsed)
        finish(succeeded: succeeded)
    }
    public mutating func processExited(at elapsed: Duration) {
        guard phase != .finished else { return }
        recordCompletionClock(elapsed); needsRestart = true; finish(succeeded: false)
    }
    private mutating func advance(at elapsed: Duration, event: Bool) -> [Intent] {
        guard phase != .finished else { return [] }
        guard elapsed >= clock else {
            if phase == .running { return beginStop(.invalidClock) }
            return [] // Never let a bad clock postpone an already-recorded Stop.
        }
        clock = elapsed
        switch phase {
        case .running:
            if let cause = deadline(at: elapsed) { return beginStop(cause) }
            if event { lastEvent = elapsed }
        case .interrupting:
            if elapsed - signalledAt >= limits.interruptGrace {
                phase = .terminating; signalledAt = elapsed; needsRestart = true; return [.terminate]
            }
        case .terminating:
            if elapsed - signalledAt >= limits.terminationGrace { phase = .killing; return [.kill] }
        case .killing, .finished: break
        }
        return []
    }
    private func deadline(at elapsed: Duration) -> StopCause? {
        let idle = lastEvent + limits.inactivity
        if limits.overall <= idle, elapsed >= limits.overall { return .overall }
        if elapsed >= idle { return .inactivity }
        return nil
    }
    private mutating func beginStop(_ cause: StopCause) -> [Intent] {
        stopCause = cause; phase = .interrupting; signalledAt = clock; return [.interrupt]
    }
    private mutating func recordCompletionClock(_ elapsed: Duration) {
        if elapsed < clock { stopCause = .invalidClock }
        else {
            clock = elapsed
            if phase == .running { stopCause = deadline(at: elapsed) }
        }
    }
    private mutating func finish(succeeded: Bool) {
        switch stopCause {
        case .person: outcome = .interrupted
        case .inactivity: outcome = .failed(.inactivity)
        case .overall: outcome = .failed(.overall)
        case .invalidClock: outcome = .failed(.invalidClock)
        case nil: outcome = succeeded ? .replied : .failed(.engineExited)
        }
        phase = .finished
    }
}
