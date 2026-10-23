import Darwin
import Foundation
import SpravaKit

/// One tool-free Claude turn, then confirmed process exit; the native session can be resumed on the next turn.
/// Only trusted runtime code may construct a launch: pinned binary, isolated home/auth, empty tools and MCP,
/// effective startup/confinement checks, and current binder consent remain its prerequisites (§11.1).
/// No runtime registration here. This read/draft transport cannot authorize or apply an operation.
package final class ClaudeReadOnlyTurn: @unchecked Sendable {
    package enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case busy, startFailed, protocolMismatch, engineFailed, endedWithoutResult, outputLimit, deadline, exitUnconfirmed, replacementRequired
        package var description: String {
            switch self {
            case .busy: "Claude is already answering in this session."
            case .startFailed: "Claude could not be started."
            case .protocolMismatch: "Claude did not match the verified session protocol."
            case .engineFailed: "Claude could not finish this request."
            case .endedWithoutResult: "Claude stopped before completing its reply."
            case .outputLimit: "Claude's reply exceeded the conversation limit."
            case .deadline: "Claude did not finish within the conversation deadline."
            case .exitUnconfirmed: "Claude has not confirmed that its process stopped."
            case .replacementRequired: "This conversation needs a fresh session from the saved app history."
            }
        }
    }
    package enum Reply: Sendable, Equatable { case text(String), interrupted }
    /// Nothing here is decoded from a model request. Environment is explicit; it is never inherited.
    package struct Launch: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let directory: URL
        let sessionID: UUID
        package init(executable: URL, arguments: [String], environment: [String: String], directory: URL, sessionID: UUID) {
            self.executable = executable; self.arguments = arguments; self.environment = environment
            self.directory = directory; self.sessionID = sessionID
        }
        package var description: String { "<Claude read-only launch>" }
        package var debugDescription: String { description }
    }
    private let launch: Launch
    private let limits: TurnSupervisorLimits
    private let lock = NSLock()
    private var active: UUID?
    private var stopped = false
    private var quarantined = false
    private var replacementRequired = false

    package init(launch: Launch, limits: TurnSupervisorLimits) { self.launch = launch; self.limits = limits }

    /// Callers durably accept the person's exact line BEFORE sending. Returned text is not proof of a change.
    /// A failed/forced turn is never retried automatically. Only canonical app history can seed its replacement.
    package func run(_ text: String, resume: Bool) async throws -> Reply {
        let frame = try ClaudeInputFrames.userLine(text, sessionID: launch.sessionID)
        let id = UUID()
        try lock.withLock {
            guard !quarantined else { throw Failure.exitUnconfirmed }
            guard !replacementRequired else { throw Failure.replacementRequired }
            guard active == nil else { throw Failure.busy }
            active = id; stopped = false
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let result = Result { try perform(text, frame: frame, resume: resume, id: id) }
                    lock.withLock {
                        if case .failure = result { replacementRequired = true }
                        if case .success(.interrupted) = result { replacementRequired = true }
                        if active == id { active = nil }
                    }
                    continuation.resume(with: result)
                }
            }
        } onCancel: { [self] in requestStop(id) }
    }

    /// Stop is repeatable and only applies to the current reservation; dropping a UI stream is not Stop.
    package func stop() { lock.withLock { if active != nil { stopped = true } } }
    private func requestStop(_ id: UUID) { lock.withLock { if active == id { stopped = true } } }
    private func isStopped(_ id: UUID) -> Bool { lock.withLock { active == id && stopped } }

    private func perform(_ text: String, frame: Data, resume: Bool, id: UUID) throws -> Reply {
        let child = try ClaudeTurnProcess(launch, resume: resume)
        defer {
            if !child.finish() { lock.withLock { quarantined = true } }
        }
        var decoder = try AgentJSONLines(maximumLineBytes: 2 * 1024 * 1024)
        var frames = ClaudeReadOnlyFrames(sessionID: launch.sessionID, original: text)
        var supervisor = TurnSupervisorPolicy(limits: limits)
        let clock = ContinuousClock(), started = ContinuousClock.now
        var outgoing = frame, offset = 0, outputBytes = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        var diagnosticOpen = true
        var pending: [TurnSupervisorPolicy.Intent] = []
        func completeStoppedProcess() throws -> Reply {
            guard child.finish() else { lock.withLock { quarantined = true }; throw Failure.exitUnconfirmed }
            if supervisor.stopCause == .person { return .interrupted }
            throw Failure.deadline
        }
        while !frames.ended {
            let elapsed = started.duration(to: clock.now)
            let intents = pending + (isStopped(id) ? supervisor.stop(at: elapsed) : supervisor.tick(at: elapsed))
            pending = []
            for intent in intents {
                switch intent {
                case .interrupt:
                    // Never splice control JSON into a partially written user frame.
                    let request = UUID(); frames.interruptID = request
                    outgoing.append(try ClaudeInputFrames.interrupt(requestID: request))
                case .terminate: child.signal(SIGTERM)
                case .kill:
                    child.signal(SIGKILL)
                    return try completeStoppedProcess()
                }
            }
            var polls = [pollfd(fd: child.output, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: diagnosticOpen ? child.error : -1, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: child.input, events: offset < outgoing.count ? Int16(POLLOUT) : 0, revents: 0)]
            let polled = poll(&polls, nfds_t(polls.count), 50)
            if polled < 0, errno != EINTR { throw Failure.engineFailed }
            if polls[2].revents & Int16(POLLOUT) != 0, offset < outgoing.count {
                let count = outgoing.withUnsafeBytes { Darwin.write(child.input, $0.baseAddress!.advanced(by: offset), outgoing.count - offset) }
                if count > 0 { offset += count }
                else if count == 0 || (errno != EAGAIN && errno != EINTR) { throw Failure.engineFailed }
            }
            for index in 0..<2 where polls[index].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(polls[index].fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    outputBytes += count
                    guard outputBytes <= 8 * 1024 * 1024 else { throw Failure.outputLimit }
                    if index == 0 {
                        do {
                            try decoder.append(Data(buffer.prefix(count))) { value in
                                try frames.receive(value)
                                // Valid frames only. The overall deadline still bounds a chatty engine.
                                pending += supervisor.event(at: started.duration(to: clock.now))
                            }
                        } catch let failure as Failure { throw failure }
                        catch { throw Failure.protocolMismatch }
                    } // stderr is counted, discarded, and never turned into an error/log message.
                } else if count == 0, index == 0, !frames.ended {
                    if supervisor.stopCause != nil { return try completeStoppedProcess() }
                    throw Failure.endedWithoutResult
                } else if count == 0, index == 1 {
                    diagnosticOpen = false
                } else if count < 0, errno != EAGAIN, errno != EINTR {
                    throw Failure.engineFailed
                }
            }
        }
        do { try decoder.finish() } catch { throw Failure.protocolMismatch }
        if isStopped(id) { _ = supervisor.stop(at: started.duration(to: clock.now)) }
        supervisor.turnFinished(at: started.duration(to: clock.now), succeeded: frames.reply != nil)
        guard child.finish() else { lock.withLock { quarantined = true }; throw Failure.exitUnconfirmed }
        if isStopped(id) { return .interrupted }
        if supervisor.phase == .terminating || supervisor.phase == .killing { return try completeStoppedProcess() }
        guard child.successfulExit else {
            if supervisor.stopCause == .person { return .interrupted }
            throw Failure.engineFailed
        }
        switch supervisor.outcome {
        case .interrupted: return .interrupted
        case .replied:
            guard let reply = frames.reply else { throw Failure.engineFailed }
            return .text(reply)
        default: throw frames.reply == nil ? Failure.engineFailed : Failure.deadline
        }
    }
}
