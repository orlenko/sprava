@testable import Services
import Brains
import Foundation
import Testing

/// The person's shell environment for a binder's commands (decisions.md D50). The shells here are invented scripts that
/// stand in for a login shell and its profile; every value is put together when the test runs.
@Suite struct PersonEnvironmentTests {
    let root: URL
    let value = "invented-" + String(repeating: "k", count: 12)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-person-environment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A stand-in shell: `profile` runs first, as a profile would, then the command given after `-l -i -c`.
    func shell(_ profile: String, runsCommand: Bool = true) throws -> String {
        let file = root.appendingPathComponent("shell-\(UUID().uuidString)")
        let body = "#!/bin/sh\n[ \"$1\" = -l ] && [ \"$2\" = -i ] && [ \"$3\" = -c ] || exit 9\n\(profile)\n\(runsCommand ? "eval \"$4\"\n" : "")"
        try Data(body.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file.path
    }

    @Test func commandsGetWhatTheShellExportsAndNothingSpravaSets() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try shell("""
        echo "a line the profile prints"
        export EXAMPLE_SERVICE_KEY=\(value)
        export EXAMPLE_REGION=north
        export PATH=/invented/bin:$PATH
        export ANTHROPIC_API_KEY=\(value)
        export HTTPS_PROXY=http://invented.example:1
        export EXAMPLE_LINES="first
        second"
        """)
        let environment = PersonEnvironment(shell: path, timeout: 10)
        let whole = try #require(environment.read())
        #expect(whole["EXAMPLE_SERVICE_KEY"] == value && whole["EXAMPLE_LINES"] == "first\nsecond" && whole["PATH"]?.hasPrefix("/invented/bin:") == true)
        // The shell starts from a login's few variables, never from this process's own environment.
        #expect(whole["HOME"] == NSHomeDirectory() && whole["SHELL"] == path)
        for name in ProcessInfo.processInfo.environment.keys where !["HOME", "USER", "LOGNAME", "SHELL", "PATH", "PWD", "OLDPWD", "SHLVL", "_"].contains(name) {
            #expect(whole[name] == nil)
        }
        let given = environment.forCommands()
        #expect(given["EXAMPLE_SERVICE_KEY"] == value && given["EXAMPLE_REGION"] == "north")
        for name in ["PATH", "HOME", "SHELL", "ANTHROPIC_API_KEY", "HTTPS_PROXY", "EXAMPLE_LINES", "PWD"] { #expect(given[name] == nil) }
        #expect(CommandVariables.usable(given))
    }

    // A profile that hangs costs the time limit and no more, and the last environment read is still given.
    @Test func aProfileThatHangsCostsTheLimitAndKeepsTheLastEnvironment() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = root.appendingPathComponent("hang")
        let path = try shell("export EXAMPLE_SERVICE_KEY=\(value)\n[ -e '\(flag.path)' ] && sleep 600")
        let environment = PersonEnvironment(shell: path, timeout: 1)
        #expect(environment.forCommands()["EXAMPLE_SERVICE_KEY"] == value)
        try Data().write(to: flag)
        let started = Date()
        #expect(environment.read() == nil)
        #expect(environment.forCommands()["EXAMPLE_SERVICE_KEY"] == value)
        #expect(Date().timeIntervalSince(started) < 8)
        #expect(PersonEnvironment(shell: path, timeout: 1).forCommands().isEmpty)
    }

    // A program the profile leaves running holds the pipe open; the answer is taken at the second mark.
    @Test func aProgramTheProfileLeftRunningIsNotWaitedFor() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try shell("export EXAMPLE_SERVICE_KEY=\(value)\nsleep 30 &")
        let started = Date()
        #expect(PersonEnvironment(shell: path, timeout: 10).forCommands()["EXAMPLE_SERVICE_KEY"] == value)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aShellThatAnswersSomethingElseGivesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // No marks at all; a shell that ends before the command; a profile that prints more than the size limit before
        // the marks; and one mark followed by more than the limit.
        #expect(PersonEnvironment(shell: try shell("echo EXAMPLE_SERVICE_KEY=\(value)", runsCommand: false), timeout: 5).read() == nil)
        #expect(PersonEnvironment(shell: try shell("exit 0"), timeout: 5).read() == nil)
        let flood = try shell("yes EXAMPLE_FILLER_LINE_OF_INVENTED_TEXT | head -c 2000000")
        #expect(PersonEnvironment(shell: flood, timeout: 5).read() == nil)
        let never = try shell("eval \"$4\" | head -c 60; yes EXAMPLE_FILLER_LINE_OF_INVENTED_TEXT | head -c 2000000", runsCommand: false)
        #expect(PersonEnvironment(shell: never, timeout: 5).read() == nil)
        // What a profile prints within the limit is passed over.
        let chatty = try shell("yes EXAMPLE_FILLER_LINE_OF_INVENTED_TEXT | head -c 200000; export EXAMPLE_SERVICE_KEY=\(value)")
        #expect(PersonEnvironment(shell: chatty, timeout: 5).forCommands()["EXAMPLE_SERVICE_KEY"] == value)
        #expect(PersonEnvironment(shell: root.appendingPathComponent("absent").path, timeout: 5).read() == nil)
        #expect(PersonEnvironment(shell: nil, timeout: 5).forCommands().isEmpty)
        #expect(PersonEnvironment(shell: root.path, timeout: 5).read() == nil)
    }

    @Test func recordsAreReadBetweenTheMarksOnly() {
        let mark = Data("mark".utf8)
        func bytes(_ text: String) -> Data { Data(text.utf8) }
        #expect(PersonEnvironment.parse(bytes("OUTSIDE=1\u{0}markA=1\u{0}B=x=y\u{0}=novalue\u{0}noequals\u{0}C=\u{0}markAFTER=1\u{0}"), mark: mark) == ["A": "1", "B": "x=y", "C": ""])
        #expect(PersonEnvironment.parse(bytes("markA=1\u{0}"), mark: mark) == nil)
        #expect(PersonEnvironment.parse(bytes("A=1\u{0}"), mark: mark) == nil)
    }

    @Test func theSessionIsToldToUseAVariableByItsNameAndNeverShowAValue() {
        let session = ClaudeConversationPolicy.session(todos: true)
        #expect(session.contains("the variables the person's shell exports") && session.contains("Never print a value"))
    }

    @Test func theLoginShellComesFromTheAccountRecord() throws {
        let shell = try #require(PersonEnvironment.loginShell())
        #expect(shell.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: shell))
    }
}
