import Darwin
import Foundation
import Testing
@testable import Brains

/// Invented subprocesses only: no installed model, authentication, profile, binder or network.
@Suite(.serialized) struct ClaudeReadOnlyTurnTests {
    private final class Fixture: Sendable {
        let directory: URL
        let runner: ClaudeReadOnlyTurn
        init(_ mode: String, inactivity: Duration = .seconds(10), overall: Duration = .seconds(20),
             environment: [String: String] = [:]) throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-turn-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = directory.appendingPathComponent("fake.py")
            try Self.script.write(to: script, atomically: true, encoding: .utf8)
            // /usr/bin/python3 is an xcrun shim that adds compiler variables. Test the interpreter itself.
            let locator = Process(), located = Pipe()
            locator.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            locator.arguments = ["--find", "python3"]; locator.standardOutput = located
            try locator.run()
            let path = String(decoding: located.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            locator.waitUntilExit()
            guard locator.terminationStatus == 0, path.hasPrefix("/") else { throw ClaudeReadOnlyTurn.Failure.startFailed }
            runner = ClaudeReadOnlyTurn(launch: .init(executable: URL(fileURLWithPath: path),
                arguments: ["-I", "-S", "-u", script.path, mode], environment: environment, directory: directory, sessionID: UUID()),
                limits: try .init(inactivity: inactivity, overall: overall, terminationGrace: .milliseconds(100)))
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func ready() async throws -> pid_t {
            let file = directory.appendingPathComponent("ready")
            for _ in 0..<1000 {
                if let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text) { return pid }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ClaudeReadOnlyTurn.Failure.startFailed
        }
        static let script = #"""
        import json, os, signal, sys, time
        mode, sid = sys.argv[1], sys.argv[-1]
        def emit(value):
            print(json.dumps(value), flush=True)
        def result(text='invented reply', failed=False):
            emit(dict(type='result', session_id=sid, subtype='error_during_execution' if failed else 'success', is_error=failed, result=text))
        if mode == 'silent':
            time.sleep(30); sys.exit(0)
        if mode == 'stubborn':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        emit(dict(type='system', subtype='init', session_id='wrong' if mode == 'session' else sid,
            tools=['shell'] if mode == 'tools' else [], mcp_servers=['outside'] if mode == 'mcp' else [],
            permissionMode='default' if mode == 'permissions' else 'dontAsk'))
        line = json.loads(sys.stdin.readline())
        assert line['client_composed'] and line['session_id'] == sid
        text = line['message']['content']
        emit(dict(type='user', session_id=sid, message=dict(role='user', content='changed' if mode == 'ack' else text)))
        with open('ready', 'w') as ready: ready.write(str(os.getpid()))
        if mode == 'echo':
            history = 'native-session'
            if sys.argv[-2] == '--resume':
                assert open(history).read() == sid
            else:
                assert not os.path.exists(history)
                with open(history, 'w') as saved: saved.write(sid)
            result(text)
        elif mode == 'isolation':
            # Python/CoreFoundation create locale metadata; all other keys must be explicitly supplied.
            unexpected = set(os.environ) - {'ALLOWED', 'EXCLUDED_FD', 'EXCLUDED_BYTES', 'LC_CTYPE', '__CF_USER_TEXT_ENCODING'}
            if unexpected:
                result('unexpected keys: ' + ','.join(sorted(unexpected))); sys.exit(0)
            assert os.environ['ALLOWED'] == 'invented'
            try: leaked = os.read(int(os.environ['EXCLUDED_FD']), 256) == os.environ['EXCLUDED_BYTES'].encode()
            except OSError: result('isolated')
            else: result('descriptor inherited' if leaked else 'isolated')
        elif mode == 'tool':
            emit(dict(type='assistant', session_id=sid, message=dict(content=[dict(type='tool_use', name='read_file')])))
        elif mode == 'truncated':
            print('{', end='', flush=True)
        elif mode == 'invalid':
            print('invented-private-marker', flush=True)
        elif mode == 'flood':
            sys.stdout.write('x' * (2 * 1024 * 1024 + 1)); sys.stdout.flush()
        elif mode == 'stderr':
            sys.stderr.write('invented-private-marker' * 400000); sys.stderr.flush()
        elif mode == 'large':
            # Larger than a pipe/read buffer: the parent must drain before interpreting process exit.
            result('a' * 200000)
        elif mode == 'error': result('invented-private-marker', True)
        elif mode == 'abnormal':
            result(); sys.exit(9)
        elif mode == 'stop':
            control = json.loads(sys.stdin.readline())
            assert control['request']['subtype'] == 'interrupt'
            emit(dict(type='control_response', response=dict(subtype='success', request_id=control['request_id'])))
            result('', True)
        elif mode == 'stubborn':
            while True: time.sleep(1)
        elif mode == 'chatter':
            while True:
                emit(dict(type='rate_limit_event')); time.sleep(.02)
        """#
    }

    @Test func exactLinesAndNativeSessionSurviveProcessRestart() async throws {
        let fixture = try Fixture("echo")
        let text = "/literal @/invented/file\nCafé \"quoted\"\n\u{0001}"
        #expect(try await fixture.runner.run(text, resume: false) == .text(text))
        #expect(try await fixture.runner.run("next invented line", resume: true) == .text("next invented line"))
    }

    @Test(arguments: ["session", "tools", "mcp", "permissions", "ack", "tool", "truncated", "invalid", "error", "abnormal", "flood", "stderr"])
    func malformedOrIncompleteResponsesAreNeverPresentedAsReplies(_ mode: String) async throws {
        let fixture = try Fixture(mode)
        do {
            _ = try await fixture.runner.run("invented input", resume: false)
            Issue.record("An invalid engine response was accepted.")
        } catch let failure as ClaudeReadOnlyTurn.Failure {
            #expect(!failure.description.contains("invented-private-marker"))
        }
        await #expect(throws: ClaudeReadOnlyTurn.Failure.replacementRequired) {
            try await fixture.runner.run("replacement", resume: true)
        }
    }

    @Test func outputIsDrainedEvenWhenTheChildHasAlreadyExited() async throws {
        let fixture = try Fixture("large")
        #expect(try await fixture.runner.run("invented", resume: false) == .text(String(repeating: "a", count: 200000)))
    }

    @Test func environmentAndUnrelatedDescriptorsDoNotReachTheChild() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-excluded-\(UUID())")
        let marker = "invented excluded descriptor \(UUID())"
        try Data(marker.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = open(file.path, O_RDONLY)
        try #require(original >= 0)
        defer { close(original) }
        let excluded = fcntl(original, F_DUPFD, 64)
        try #require(excluded >= 64)
        defer { close(excluded) }
        let fixture = try Fixture("isolation", environment: ["ALLOWED": "invented", "EXCLUDED_FD": String(excluded), "EXCLUDED_BYTES": marker])
        let reply = try await fixture.runner.run("invented", resume: false)
        #expect(reply == .text("isolated"))
    }

    @Test func stopIsCorrelatedAndTheSessionIsReservedUntilConfirmedExit() async throws {
        let fixture = try Fixture("stop")
        let task = Task { try await fixture.runner.run("invented", resume: false) }
        let pid = try await fixture.ready()
        await #expect(throws: ClaudeReadOnlyTurn.Failure.busy) { try await fixture.runner.run("second", resume: true) }
        fixture.runner.stop(); fixture.runner.stop()
        #expect(try await task.value == .interrupted)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        await #expect(throws: ClaudeReadOnlyTurn.Failure.replacementRequired) { try await fixture.runner.run("second", resume: true) }
    }

    @Test func cancellationAlsoInterruptsAndConfirmsExit() async throws {
        let fixture = try Fixture("stop")
        let task = Task { try await fixture.runner.run("invented", resume: false) }
        let pid = try await fixture.ready()
        task.cancel()
        #expect(try await task.value == .interrupted)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func aPersonStopKillsAnUncooperativeChildBeforeReturning() async throws {
        let fixture = try Fixture("stubborn")
        let task = Task { try await fixture.runner.run("invented", resume: false) }
        let pid = try await fixture.ready()
        fixture.runner.stop()
        #expect(try await task.value == .interrupted)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test(arguments: ["silent", "chatter", "stubborn"])
    func silenceChatterAndAnIgnoredStopHaveBoundedLifetimes(_ mode: String) async throws {
        let fixture = try Fixture(mode, inactivity: .milliseconds(200), overall: .milliseconds(300))
        let began = ContinuousClock.now
        await #expect(throws: ClaudeReadOnlyTurn.Failure.deadline) { try await fixture.runner.run("invented", resume: false) }
        #expect(began.duration(to: .now) < .seconds(12))
    }
}
