@testable import Brains
import Darwin
import Foundation
import Testing

/// How the helper process is started and ended (docs/conversation.md 11.2): the model as descriptor 3 and no other
/// descriptor or environment inherited; SIGKILL for a helper that ignores SIGTERM; helpers left by an earlier
/// runtime are ended. System tools stand in for `sprava-llm`; invented files only.
@Suite(.serialized) struct LLMSpawnTests {
    func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("llm-spawn-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func waitUntilEnded(_ process: SpawnedLLM) {
        for _ in 0..<500 where process.isRunning { usleep(10_000) }
    }

    @Test func theModelIsDescriptorThreeAndNothingElseIsInherited() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("model.gguf")
        try Data("invented weights".utf8).write(to: model)
        let fd = open(model.path, O_RDONLY | O_CLOEXEC)
        defer { close(fd) }
        // A descriptor this process holds open without close-on-exec must still not reach the helper.
        let other = open(model.path, O_RDONLY)
        defer { close(other) }
        let script = "cat <&3 > out; [ -e /dev/fd/\(other) ] && echo open > leak; env > env; exit 0"
        let shell = try SpawnedLLM.spawn(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cd '\(dir.path)' && \(script)"], fd: fd)
        waitUntilEnded(shell)
        #expect(!shell.isRunning)
        #expect(try String(contentsOf: dir.appendingPathComponent("out"), encoding: .utf8) == "invented weights")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("leak").path))
        let env = try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8)
        #expect(!env.contains("HOME=") && !env.contains("SPRAVA_"))
    }

    @Test func aHelperThatIgnoresSIGTERMIsKilled() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { close(fd) }
        let stubborn = try SpawnedLLM.spawn(URL(fileURLWithPath: "/bin/sh"),
                                            arguments: ["-c", "trap '' TERM; touch '\(dir.path)/ready'; while :; do :; done"], fd: fd)
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("ready").path) { usleep(10_000) }
        let started = Date()
        stubborn.stop(grace: 0.3)
        #expect(!stubborn.isRunning)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func helpersLeftByAnEarlierRuntimeAreEnded() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A copy of a system tool plays a helper whose runtime ended: started in the background by a shell that exits,
        // so launchd adopts it. The copy is signed again, since a system tool moved out of its folder is not run.
        let helper = dir.appendingPathComponent("sprava-llm")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: helper)
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { close(fd) }
        waitUntilEnded(try SpawnedLLM.spawn(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", helper.path], fd: fd))
        let parent = try SpawnedLLM.spawn(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "'\(helper.path)' 30 & exit 0"], fd: fd)
        waitUntilEnded(parent)
        var ended = 0
        for _ in 0..<200 where ended == 0 { ended = SpawnedLLM.endOrphans(of: helper); usleep(10_000) }
        #expect(ended == 1)
        usleep(100_000)
        #expect(SpawnedLLM.endOrphans(of: helper) == 0)
        // A helper whose parent is alive is not touched.
        let child = try SpawnedLLM.spawn(helper, arguments: ["30"], fd: fd)
        defer { child.stop(grace: 0.5) }
        #expect(SpawnedLLM.endOrphans(of: helper) == 0)
        #expect(child.isRunning)
    }
}
