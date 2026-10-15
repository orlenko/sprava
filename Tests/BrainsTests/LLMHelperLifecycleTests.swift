@testable import Brains
import Darwin
import Foundation
import SpravaKit
import Testing

/// When `LLMHelper` starts and stops the local model's helper (docs/conversation.md 11.2): on the first call, once
/// `/health` says the model is loaded; stopped after the idle minutes; never started unsandboxed; its arguments keep
/// it on a Unix socket in its container with the model on descriptor 3. Fakes and invented data only.
@Suite(.serialized) struct LLMHelperLifecycleTests {
    let question = [LLMHelper.Message(.user, "Is the invented plant watered?")]

    @Test func theFirstCallStartsTheHelperAndWaitsUntilTheModelIsLoaded() throws {
        let probes = Locked(0)
        let (helper, launches) = fakeHelper { request in
            request.target == "/health" && probes.update { $0 += 1 } < 2 ? .json(503, #"{"error":"loading"}"#) : FakeLLMServer.healthy()(request)
        }
        defer { helper.stop() }
        #expect(!helper.isRunning)
        _ = try helper.complete(question, schema: inventedSchema)
        #expect(helper.isRunning)
        #expect(try #require(launches.value.first).requests.filter { $0.target == "/health" }.count == 3)
        _ = try helper.complete(question, schema: inventedSchema)
        #expect(launches.value.count == 1)
    }

    @Test func aHelperThatNeverBecomesHealthyOrExitsFailsToStart() throws {
        var limits = LLMHelper.Limits()
        limits.start = 0.4
        let (helper, launches) = fakeHelper(limits: limits) { _ in .json(503, #"{"error":"loading"}"#) }
        #expect(throws: LLMHelper.Failure(.startFailed)) { try helper.complete(question, schema: inventedSchema) }
        #expect(launches.value.first?.isRunning == false)
        let log = Locked<[String]>([])
        let exited = LLMHelper(socket: llmSocketPath(), limits: .init(), log: { line in log.update { $0.append(line) } }) { _, _ in Exited() }
        #expect(throws: LLMHelper.Failure(.startFailed)) { try exited.complete(question, schema: inventedSchema) }
        #expect(log.value.contains("llm stop reason=exited"))
        let refused = LLMHelper(socket: llmSocketPath(), limits: .init(), log: { line in log.update { $0.append(line) } }) { _, _ in
            throw LLMHelper.Failure(.unsandboxed)
        }
        #expect(throws: LLMHelper.Failure(.unsandboxed)) { try refused.complete(question, schema: inventedSchema) }
        #expect(log.value.contains("llm start outcome=unsandboxed"))
    }

    @Test func anIdleHelperIsStoppedAfterFifteenMinutesAndStartedAgainWhenNeeded() throws {
        let clock = Locked<TimeInterval>(1_000)
        let (helper, launches) = fakeHelper(clock: clock)
        defer { helper.stop() }
        #expect(!helper.stopIfIdle())
        _ = try helper.complete(question, schema: inventedSchema)
        clock.update { $0 += 14 * 60 }
        #expect(!helper.stopIfIdle())
        #expect(helper.isRunning)
        clock.update { $0 += 60 }
        #expect(helper.stopIfIdle())
        #expect(!helper.isRunning)
        #expect(launches.value.first?.isRunning == false)
        _ = try helper.complete(question, schema: inventedSchema)
        #expect(launches.value.count == 2)
    }

    @Test func aSocketLeftByAnEndedHelperIsReplacedAndNothingElseIsRemoved() throws {
        let socket = llmSocketPath()
        // llama-server leaves its socket file behind when it ends; a bound and closed socket is the same.
        let leftover = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try #require(unixAddress(socket))
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(leftover, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(leftover)
        let helper = LLMHelper(socket: socket, limits: .init(), log: { _ in }) { socket, _ in try FakeLLMServer(path: socket) }
        _ = try helper.complete(question, schema: inventedSchema)
        helper.stop()
        // A file that is not a socket is never removed, and the helper is not started over it.
        try Data("invented".utf8).write(to: URL(fileURLWithPath: socket))
        defer { unlink(socket) }
        #expect(throws: LLMHelper.Failure(.startFailed)) { try helper.complete(question, schema: inventedSchema) }
        #expect(FileManager.default.contents(atPath: socket) == Data("invented".utf8))
    }

    @Test func theHelperListensOnlyOnItsSocketWithTheModelOnDescriptorThree() throws {
        let socket = LLMHelper.socketPath(home: "/Users/example")
        #expect(socket == "/Users/example/Library/Containers/ca.orlenko.sprava.llm/Data/tmp/llm.sock")
        #expect(LLMHelper.arguments(socket: socket, limits: .init()) == [
            "-m", "/dev/fd/3", "--host", socket, "-c", "8192", "-ngl", "99", "-np", "1",
            "--no-ui", "--no-slots", "--sleep-idle-seconds", "60",
        ])
        // A home folder whose path leaves the socket over the 104-byte limit is refused before anything starts.
        let long = LLMHelper(socket: LLMHelper.socketPath(home: "/Users/" + String(repeating: "e", count: 60)), limits: .init(),
                             log: { _ in }) { socket, _ in try FakeLLMServer(path: socket) }
        #expect(throws: LLMHelper.Failure(.socketPath)) { try long.complete(question, schema: inventedSchema) }
    }

    @Test func aHelperWithoutItsSandboxOrModelIsNotStarted() throws {
        let model = URL(fileURLWithPath: NSTemporaryDirectory() + "llm-model-\(UUID().uuidString.prefix(8)).gguf")
        try Data("invented weights".utf8).write(to: model)
        defer { try? FileManager.default.removeItem(at: model) }
        let socket = llmSocketPath()
        #expect(throws: LLMHelper.Failure(.missing)) {
            _ = try LLMHelper.launchSandboxed(URL(fileURLWithPath: "/nonexistent/sprava-llm"), model: model, socket: socket, limits: .init())
        }
        // A signed system tool carries no App Sandbox entitlement.
        #expect(throws: LLMHelper.Failure(.unsandboxed)) {
            _ = try LLMHelper.launchSandboxed(URL(fileURLWithPath: "/bin/sleep"), model: model, socket: socket, limits: .init())
        }
    }
}

/// A helper that ended as soon as it started.
final class Exited: LLMProcess {
    var isRunning: Bool { false }
    func stop(grace: TimeInterval) {}
}
