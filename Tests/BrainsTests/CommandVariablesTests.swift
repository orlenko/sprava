@testable import Brains
import Foundation
import Testing

/// The variables a person sets for one binder's commands (decisions.md D50). Every value here is invented and put
/// together when the test runs.
@Suite struct CommandVariablesTests {
    let root: URL
    let binder: URL
    let home: URL
    let value = "invented-" + String(repeating: "k", count: 12)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-command-variables-\(UUID().uuidString)")
        binder = root.appendingPathComponent("binder")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: binder, withIntermediateDirectories: true)
    }

    func plan(_ variables: [String: String]) throws -> ClaudeReadOnlyTurn.Launch {
        try ClaudeReadLaunch.plan(program: URL(fileURLWithPath: "/opt/invented/2.1.332"), home: home, sessionID: UUID(), credential: "invented",
                                  policy: "p", reach: .init(folder: binder, proxyPort: 4242, variables: variables))
    }

    var file: URL { home.resolvingSymlinksInPath().appendingPathComponent("command-env.sh") }

    /// What a shell that ran the file holds under `name`, byte for byte.
    func shell(_ name: String) throws -> String {
        let task = Process(), out = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", ". \"$1\"; printf %s \"$\(name)\"", "sh", file.path]
        task.environment = [:]
        task.standardOutput = out
        try task.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // The CLI's scrub takes a key-like name out of what commands inherit, so the values travel in a file it runs before
    // each command, and are in no environment and no argument.
    @Test func aBindersVariablesReachItsCommandsThroughAFileOfTheSessionsHome() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = try plan(["EXAMPLE_SERVICE_KEY": value, "EXAMPLE_REGION": "north"])
        #expect(launch.environment["CLAUDE_ENV_FILE"] == file.path)
        #expect(launch.environment["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == "1")
        #expect(launch.environment["EXAMPLE_SERVICE_KEY"] == nil && !launch.environment.values.contains { $0.contains(value) })
        #expect(!launch.arguments.contains { $0.contains(value) } && !String(reflecting: launch).contains(value))
        #expect(try String(contentsOf: file, encoding: .utf8) == "export EXAMPLE_REGION='north'\nexport EXAMPLE_SERVICE_KEY='\(value)'\n")
        let mode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        #expect(try shell("EXAMPLE_SERVICE_KEY") == value && shell("EXAMPLE_REGION") == "north")
    }

    // What carries the variables to the launch shows how many there are and nothing of them, however it is printed.
    @Test func whatCarriesTheVariablesNeverShowsOne() {
        let reach = ClaudeReadLaunch.Reach(folder: binder, proxyPort: 4242, variables: ["EXAMPLE_SERVICE_KEY": value])
        var dumped = ""
        dump(reach, to: &dumped)
        for text in ["\(reach)", String(describing: reach), String(reflecting: reach), dumped, "\([reach])", "\(Optional(reach) as Any)"] {
            #expect(!text.contains(value) && !text.contains("EXAMPLE_SERVICE_KEY"))
        }
        #expect("\(reach)".contains("variables: 1"))
    }

    @Test func aValueReachesTheShellByteForByte() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let odd = "it's $HOME `id` \"q\" \\n ; rm -rf x # é ' ''"
        _ = try plan(["EXAMPLE_ODD": odd])
        #expect(try shell("EXAMPLE_ODD") == odd)
    }

    // A value the person removed does not stay in the session's home, and the CLI is pointed at no file.
    @Test func aSessionStartedWithoutVariablesLeavesNoneBehind() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try plan(["EXAMPLE_SERVICE_KEY": value])
        let launch = try plan([:])
        #expect(launch.environment["CLAUDE_ENV_FILE"] == nil)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test(arguments: ["PATH", "path", "HOME", "HTTPS_PROXY", "https_proxy", "NO_PROXY", "TMPDIR", "BASH_ENV", "CLAUDE_ENV_FILE",
                      "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "DYLD_INSERT_LIBRARIES", "PWD", "TERM_PROGRAM",
                      "LC_ALL", "__CF_USER_TEXT_ENCODING", "", "1ST", "A-B", "A B", "A=B", "Ключ", String(repeating: "A", count: 129)])
    func aNameSpravaSetsOrTheShellCannotHoldIsLeftOutAndStartsNoSession(_ name: String) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!CommandVariables.takes(name: name))
        #expect(CommandVariables.passable([name: value, "EXAMPLE_SERVICE_KEY": value]) == ["EXAMPLE_SERVICE_KEY": value])
        // The launch takes only a set already cut down, so a caller that forgot to cut it starts nothing.
        #expect(throws: ClaudeReadLaunch.Refused.invalidInput) { _ = try plan([name: value]) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func ordinaryNamesAndValuesAreTaken() {
        for name in ["OPENAI_API_KEY", "EXAMPLE_SERVICE_TOKEN", "_private", "region2", "EDITOR", "GOPATH"] { #expect(CommandVariables.takes(name: name)) }
        #expect(CommandVariables.takes(value: value))
        #expect(CommandVariables.takes(value: String(repeating: "v", count: CommandVariables.maximumValueBytes)))
    }

    @Test func aValueIsOneLineWithinTheLimit() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for bad in ["", "two\nlines", "tab\there", "nul\u{0}", "sep\u{2028}", String(repeating: "v", count: CommandVariables.maximumValueBytes + 1)] {
            #expect(!CommandVariables.takes(value: bad))
            #expect(CommandVariables.passable(["EXAMPLE_SERVICE_KEY": bad, "EXAMPLE_REGION": "north"]) == ["EXAMPLE_REGION": "north"])
            #expect(throws: ClaudeReadLaunch.Refused.invalidInput) { _ = try plan(["EXAMPLE_SERVICE_KEY": bad]) }
        }
    }

    // A very large environment is cut by count and by size, the same way every time, and what is kept still starts a session.
    @Test func aVeryLargeEnvironmentIsCutTheSameWayEveryTime() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var many: [String: String] = [:]
        for i in 0..<(CommandVariables.maximumCount + 40) { many[String(format: "EXAMPLE_%04d", i)] = "v" }
        let kept = CommandVariables.passable(many)
        #expect(kept.count == CommandVariables.maximumCount && kept["EXAMPLE_0000"] == "v" && kept[String(format: "EXAMPLE_%04d", CommandVariables.maximumCount)] == nil)
        #expect(CommandVariables.passable(many) == kept)
        var heavy: [String: String] = [:]
        for i in 0..<64 { heavy[String(format: "EXAMPLE_%04d", i)] = String(repeating: "v", count: CommandVariables.maximumValueBytes) }
        let fits = CommandVariables.passable(heavy)
        #expect(fits.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } <= CommandVariables.maximumBytes && fits.count >= 30)
        #expect(throws: ClaudeReadLaunch.Refused.invalidInput) { _ = try plan(many) }
        _ = try plan(kept)
        #expect(try shell("EXAMPLE_0000") == "v")
    }
}
