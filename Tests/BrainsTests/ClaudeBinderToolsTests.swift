import Darwin
import Foundation
import Network
import SpravaKit
import Testing
@testable import Brains

/// The binder agent's walls and stream contract. The sandbox tests run a real shell under the real profile against
/// invented folders; no model is involved.
@Suite struct ClaudeBinderToolsTests {
    struct Fixture {
        let root: URL, binder: URL, other: URL, home: URL, profile: URL, session = UUID()
        func clean() { try? FileManager.default.removeItem(at: root) }
        init(proxyPort: UInt16 = 9) throws {
            // Under the checkout's build folder: on /Users or /Volumes, where a person's folders are and the walls apply. Invented.
            let build = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build")
            root = URL(fileURLWithPath: String(cString: realpath(build.path, nil))).appendingPathComponent("sprava-walls-\(UUID().uuidString)")
            binder = root.appendingPathComponent("My (binder) v1.0"); other = root.appendingPathComponent("other")
            home = root.appendingPathComponent("home"); profile = root.appendingPathComponent("profile.sb")
            for folder in [binder.appendingPathComponent(".sprava"), binder.appendingPathComponent("scripts"), other, home] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            for (text, path) in [("notes", "notes.md"), ("old", "old.md"), ("log", ".sprava/ops.jsonl"), ("{}", "catalog.json"),
                                 ("INVENTED=1", "scripts/.env"), ("INVENTED KEY", "scripts/deploy.pem")] {
                try Data(text.utf8).write(to: binder.appendingPathComponent(path))
            }
            try Data("private".utf8).write(to: other.appendingPathComponent("private.md"))
            let text = ClaudeReadLaunch.sandbox(home: home, program: URL(fileURLWithPath: "/opt/invented/claude"),
                                                reach: .init(folder: binder, proxyPort: proxyPort), session: session)
            try Data(text.utf8).write(to: profile)
        }
        /// Whether the command succeeded inside the walls.
        func allowed(_ command: String) throws -> Bool {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            task.arguments = ["-f", profile.path, "/bin/sh", "-c", command]
            task.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path, "B": binder.path, "O": other.path]
            task.currentDirectoryURL = binder
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            try task.run(); task.waitUntilExit()
            return task.terminationStatus == 0
        }
    }

    @Test func insideTheBinderItCanDoTheWork() throws {
        let f = try Fixture(); defer { f.clean() }
        #expect(try f.allowed("cat notes.md && ls && find . -name 'n*' && grep notes notes.md"))
        #expect(try f.allowed("echo new > new.md && mkdir -p d/e && mv new.md d/e/new.md"))
        #expect(try f.allowed("rm old.md"))
        #expect(!FileManager.default.fileExists(atPath: f.binder.appendingPathComponent("old.md").path))
        #expect(try f.allowed("echo own > \"$HOME/own.txt\""))
    }

    @Test func keyFilesCanBeDeletedButNotRead() throws {
        let f = try Fixture(); defer { f.clean() }
        #expect(try !f.allowed("cat scripts/.env"))
        #expect(try !f.allowed("grep INVENTED scripts/deploy.pem"))
        #expect(try f.allowed("rm scripts/.env"))
        #expect(!FileManager.default.fileExists(atPath: f.binder.appendingPathComponent("scripts/.env").path))
    }

    @Test func sprawasOwnFilesAreClosed() throws {
        let f = try Fixture(); defer { f.clean() }
        #expect(try f.allowed("cat .sprava/ops.jsonl && find . >/dev/null"))
        #expect(try !f.allowed("echo x >> .sprava/ops.jsonl"))
        #expect(try !f.allowed("rm .sprava/ops.jsonl"))
        #expect(try !f.allowed("mv .sprava elsewhere"))
        #expect(try !f.allowed("echo x > catalog.json"))
        #expect(try !f.allowed("mv catalog.json c.json"))
        #expect(try !f.allowed("echo x > DASHBOARD.md"))
        // Closing the binder itself would stop Sprava recording the turn.
        #expect(try !f.allowed("chmod 000 ."))
        #expect(try !f.allowed("chflags uchg ."))
        #expect(try f.allowed("mkdir -p sub && chmod 700 sub"))
        // On a case-insensitive volume, the same files by another spelling.
        #expect(try !f.allowed("echo x > CATALOG.JSON"))
        #expect(try !f.allowed("echo x >> .SPRAVA/ops.jsonl"))
    }

    @Test func nothingOutsideTheBinderIsReachable() throws {
        let f = try Fixture(); defer { f.clean() }
        #expect(try !f.allowed("cat \"$O/private.md\""))
        #expect(try !f.allowed("echo x > \"$O/x\""))
        #expect(try !f.allowed("echo x > /private/tmp/sprava-wall-probe-\(UUID().uuidString)"))
        #expect(try !f.allowed("ln -s \"$O/private.md\" link.md && cat link.md"))
        #expect(try !f.allowed("ls /Users/*/.ssh"))
        // Reads are closed everywhere else too, temporary folders included.
        let stray = URL(fileURLWithPath: "/private/tmp/sprava-wall-\(UUID().uuidString).txt")
        try Data("invented".utf8).write(to: stray); defer { try? FileManager.default.removeItem(at: stray) }
        #expect(try !f.allowed("cat \(stray.path)"))
        #expect(try !f.allowed("ls /private/var/folders"))
        // Homebrew's and the system's application data, as opposed to their programs.
        #expect(try !f.allowed("ls /opt/homebrew/var"))
        #expect(try !f.allowed("ls '/Library/Application Support'"))
        #expect(try !f.allowed("ls /Library/Keychains"))
        // What commands need still reads: the system's own files, and looking up a path.
        #expect(try f.allowed("cat /etc/hosts >/dev/null && /usr/bin/sw_vers >/dev/null && pwd && test -d /private/tmp"))
    }

    @Test func aDetachedCommandEndsWithTheTurnAndAnotherSessionsIsLeftAlone() async throws {
        let f = try Fixture(); defer { f.clean() }
        let other = try Fixture(); defer { other.clean() }
        // Double fork, a new session, closed streams and a clean environment: the shape that outlives a process group.
        let daemon = #"exec /usr/bin/env -i /usr/bin/perl -e 'use POSIX; fork and exit; POSIX::setsid(); fork and exit; close STDIN; close STDOUT; close STDERR; sleep 30'"#
        #expect(try f.allowed(daemon))
        #expect(try other.allowed(daemon))
        for _ in 0..<50 where AgentContainment.running(session: f.session).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let left = AgentContainment.running(session: f.session)
        #expect(left.count == 1)
        #expect(AgentContainment.running(session: other.session).count == 1)
        #expect(!AgentContainment.running(session: UUID()).contains(where: left.contains))
        #expect(AgentContainment.sweep(session: f.session))
        #expect(AgentContainment.running(session: f.session).isEmpty)
        #expect(AgentContainment.running(session: other.session).count == 1)
        #expect(AgentContainment.sweep(session: other.session))
    }

    @Test func sweepingANeverUsedSessionFindsNothingAndTouchesNoOrdinaryProcess() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["10"]
        try sleeper.run(); defer { sleeper.terminate() }
        #expect(AgentContainment.running(session: UUID()).isEmpty)
        #expect(AgentContainment.sweep(session: UUID()))
        #expect(sleeper.isRunning)
    }

    @Test func theOnlyWayOutIsTheProxysPort() throws {
        let proxy = try AgentEgressProxy(allowed: []); defer { proxy.stop() }
        let f = try Fixture(proxyPort: proxy.port); defer { f.clean() }
        #expect(try !f.allowed("/bin/bash -c 'exec 3<>/dev/tcp/93.184.216.34/443'"))
        #expect(try !f.allowed("curl -sS -m 4 --noproxy '*' https://example.invalid -o /dev/null"))
        #expect(try f.allowed("/bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/\(proxy.port)'"))
    }

    @Test func aCommandCannotListenForAConnection() throws {
        let f = try Fixture(); defer { f.clean() }
        // A listening port would hand a document to whatever connects, past the proxy.
        #expect(try !f.allowed(#"/usr/bin/perl -e 'use Socket; socket(S, PF_INET, SOCK_STREAM, 6) or exit 3; bind(S, pack_sockaddr_in(0, INADDR_ANY)) or exit 4; listen(S, 1) or exit 5; exit 0'"#))
    }

    @Test func toolsThatReachOtherAppsWillNotRun() throws {
        let f = try Fixture(); defer { f.clean() }
        for command in ["/usr/bin/open .", "echo x | /usr/bin/pbcopy", "/usr/bin/security list-keychains", "/usr/bin/osascript -e 1", "/bin/launchctl list"] {
            #expect(try !f.allowed(command))
        }
    }

    @Test func aRealCommandCannotSignalAnotherProcess() throws {
        let f = try Fixture(); defer { f.clean() }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["30"]
        try sleeper.run(); defer { sleeper.terminate() }
        #expect(try !f.allowed("kill \(sleeper.processIdentifier)"))
        #expect(sleeper.isRunning)
    }

    @Test func theProxyPassesOnlyAnAllowedHostsTLSPort() {
        func target(_ line: String) -> String? {
            AgentEgressProxy.target(of: Data((line + "\r\nHost: x").utf8), allowed: AgentEgressProxy.modelHosts)
        }
        #expect(target("CONNECT api.anthropic.com:443 HTTP/1.1") == "api.anthropic.com")
        #expect(target("CONNECT API.anthropic.com:443 HTTP/1.1") == "api.anthropic.com")
        #expect(target("CONNECT api.anthropic.com:80 HTTP/1.1") == nil)
        #expect(target("CONNECT example.invalid:443 HTTP/1.1") == nil)
        #expect(target("CONNECT api.anthropic.com.example.invalid:443 HTTP/1.1") == nil)
        #expect(target("GET http://api.anthropic.com/ HTTP/1.1") == nil)
        #expect(target("CONNECT api.anthropic.com:443") == nil)
    }

    @Test func theProxyRefusesAnOtherHostOnTheWire() async throws {
        let proxy = try AgentEgressProxy(allowed: []); defer { proxy.stop() }
        #expect(try connectStatus(proxy: proxy, host: "example.invalid") == "403")
    }

    /// `curl`'s view of a CONNECT through the proxy: its own process, which is not the agent unless authorized.
    func connectStatus(proxy: AgentEgressProxy, host: String, authorizeCurl: Bool = false) throws -> String {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-sS", "-m", "5", "--proxy", "http://127.0.0.1:\(proxy.port)", "https://\(host)/", "-o", "/dev/null", "-w", "%{http_connect}"]
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        try task.run()
        if authorizeCurl { proxy.authorize(task.processIdentifier) }
        task.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// The status line of a CONNECT sent from this process.
    func connectFromHere(proxy: AgentEgressProxy, host: String) throws -> String {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0); defer { close(socket) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_port = proxy.port.bigEndian
        let joined = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(joined == 0)
        let request = "CONNECT \(host):443 HTTP/1.1\r\nHost: \(host)\r\n\r\n"
        _ = request.withCString { write(socket, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let got = read(socket, &buffer, 256)
        return got > 0 ? String(decoding: buffer.prefix(got), as: UTF8.self).components(separatedBy: "\r\n")[0] : ""
    }

    @Test func onlyTheAgentProcessCanUseTheProxy() throws {
        // A plain local listener stands in for the model's host.
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { $0.start(queue: .global()) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global()); defer { listener.cancel() }
        #expect(ready.wait(timeout: .now() + 5) == .success)
        let port = try #require(listener.port?.rawValue)
        let proxy = try AgentEgressProxy(allowed: ["localhost"], upstreamPort: port); defer { proxy.stop() }
        // Nobody authorized, then someone else authorized: a command holding a good host and any key still gets nowhere.
        #expect(try connectStatus(proxy: proxy, host: "localhost") == "403")
        proxy.authorize(getpid())
        #expect(try connectStatus(proxy: proxy, host: "localhost") == "403")
        // The authorized process itself gets through, to an allowed host only.
        #expect(try connectFromHere(proxy: proxy, host: "localhost").contains("200"))
        #expect(try connectFromHere(proxy: proxy, host: "example.invalid").contains("403"))
    }

    @Test func theKernelSaysWhichProcessHoldsAConnection() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0); defer { close(socket) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        let port = UInt16(bigEndian: address.sin_port)
        #expect(AgentEgressProxy.holdsConnection(getpid(), fromPort: port))
        #expect(!AgentEgressProxy.holdsConnection(getpid(), fromPort: port &+ 1))
        #expect(!AgentEgressProxy.holdsConnection(1, fromPort: port))
    }

    @Test func aCopiedLaunchctlCannotStartAJobOutsideTheSandbox() throws {
        let f = try Fixture(); defer { f.clean() }
        let label = "ca.orlenko.sprava.invented-wall-\(UUID().uuidString.lowercased())"
        defer { let remove = Process(); remove.executableURL = URL(fileURLWithPath: "/bin/launchctl"); remove.arguments = ["remove", label]; try? remove.run(); remove.waitUntilExit() }
        #expect(try !f.allowed("cp /bin/launchctl \"$HOME/lc\" && \"$HOME/lc\" submit -l \(label) -- /usr/bin/true"))
    }

    @Test func aLaunchWithReachOffersTheToolsInTheBinderAndOneWithoutOffersNone() throws {
        let f = try Fixture(); defer { f.clean() }
        let credential = "invented", program = URL(fileURLWithPath: "/opt/invented/2.1.316")
        let free = try ClaudeReadLaunch.plan(program: program, home: f.root.appendingPathComponent("free"), sessionID: UUID(), credential: credential, policy: "p")
        #expect(free.tools.isEmpty && free.arguments.contains("*") && free.environment["HTTPS_PROXY"] == nil)
        let tools = try ClaudeReadLaunch.plan(program: program, home: f.root.appendingPathComponent("tools"), sessionID: UUID(), credential: credential, policy: "p",
                                              reach: .init(folder: f.binder, proxyPort: 4242))
        #expect(tools.tools == Set(["Read", "Write", "Edit", "Glob", "Grep", "Bash"]))
        #expect(tools.directory.path == f.binder.path)
        #expect(tools.environment["HTTPS_PROXY"] == "http://127.0.0.1:4242")
        #expect(!tools.arguments.contains("*") && !tools.arguments.contains("WebFetch") && !tools.arguments.contains("Task"))
        #expect(tools.arguments.contains("dontAsk") && tools.arguments.contains("--restricted"))
        #expect(tools.environment["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == "1")
        #expect(tools.environment["CLAUDE_CONFIG_DIR"]?.hasPrefix(f.root.path) == true)
    }

    // MARK: - The stream, in the shape Claude 2.1.316 sends for a turn that uses tools.

    let session = UUID()
    func frame(_ json: String) throws -> JSONObject { try #require(JSONParser.parse(json).value.objectValue) }
    func started(_ tools: Set<String>, original: String = "Tidy") throws -> ClaudeReadOnlyFrames {
        var frames = ClaudeReadOnlyFrames(sessionID: session, original: original, tools: tools)
        let id = session.uuidString.lowercased()
        let list = tools.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        try frames.receive(frame(#"{"type":"system","subtype":"init","session_id":"\#(id)","tools":[\#(list)],"mcp_servers":[],"permissionMode":"dontAsk"}"#))
        try frames.receive(frame(#"{"type":"user","session_id":"\#(id)","parent_tool_use_id":null,"isReplay":true,"message":{"role":"user","content":"\#(original)"}}"#))
        return frames
    }

    @Test func aTurnThatUsesItsToolsReachesItsReply() throws {
        var frames = try started(["Bash", "Read"])
        let id = session.uuidString.lowercased()
        try frames.receive(frame(#"{"type":"assistant","session_id":"\#(id)","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm old.md"}}]}}"#))
        try frames.receive(frame(#"{"type":"user","session_id":"\#(id)","parent_tool_use_id":null,"tool_use_result":{},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Tidy"}]}}"#))
        try frames.receive(frame(#"{"type":"assistant","session_id":"\#(id)","parent_tool_use_id":null,"message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#))
        try frames.receive(frame(#"{"type":"result","subtype":"success","is_error":false,"session_id":"\#(id)","result":"the reply"}"#))
        #expect(frames.reply == "the reply" && frames.ended)
    }

    @Test func theModeTheCLIForcesWhenItScrubsIsAcceptedOnlyWithTools() throws {
        let id = session.uuidString.lowercased()
        let forced = #"{"type":"system","subtype":"init","session_id":"\#(id)","tools":[%TOOLS%],"mcp_servers":[],"permissionMode":"default"}"#
        var tools = ClaudeReadOnlyFrames(sessionID: session, original: "Tidy", tools: ["Read"])
        try tools.receive(frame(forced.replacingOccurrences(of: "%TOOLS%", with: "\"Read\"")))
        #expect(tools.initialized)
        var free = ClaudeReadOnlyFrames(sessionID: session, original: "Tidy")
        #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) { try free.receive(frame(forced.replacingOccurrences(of: "%TOOLS%", with: ""))) }
    }

    @Test func aToolThatWasNotOfferedFailsTheTurn() throws {
        var frames = try started(["Read"])
        let id = session.uuidString.lowercased()
        #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) {
            try frames.receive(frame(#"{"type":"assistant","session_id":"\#(id)","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"WebFetch","input":{}}]}}"#))
        }
    }

    @Test func aSessionOfferingMoreThanItWasGivenFailsAtTheStart() throws {
        var frames = ClaudeReadOnlyFrames(sessionID: session, original: "Tidy", tools: ["Read"])
        let id = session.uuidString.lowercased()
        #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) {
            try frames.receive(frame(#"{"type":"system","subtype":"init","session_id":"\#(id)","tools":["Read","WebFetch"],"mcp_servers":[],"permissionMode":"dontAsk"}"#))
        }
    }

    @Test func aToolFreeSessionStillRefusesEveryTool() throws {
        var frames = try started([])
        let id = session.uuidString.lowercased()
        #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) {
            try frames.receive(frame(#"{"type":"assistant","session_id":"\#(id)","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}"#))
        }
        #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) {
            try frames.receive(frame(#"{"type":"user","session_id":"\#(id)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"x"}]}}"#))
        }
    }
}
