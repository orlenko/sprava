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
        /// `allowing`: programs a test needs in order to probe a wall behind the command list; the real profile has none of them.
        init(proxyPort: UInt16 = 9, allowing: [String] = []) throws {
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
            var text = ClaudeReadLaunch.sandbox(home: home, program: URL(fileURLWithPath: "/opt/invented/claude"),
                                                reach: .init(folder: binder, proxyPort: proxyPort), session: session)
            for program in allowing { text += "\n(allow process-exec (literal \"\(program)\"))" }
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
        #expect(try f.allowed("ls && echo new > new.md && mkdir -p d/e && mv new.md d/e/new.md"))
        #expect(try f.allowed("rm old.md"))
        #expect(!FileManager.default.fileExists(atPath: f.binder.appendingPathComponent("old.md").path))
        #expect(try f.allowed("echo own > \"$HOME/own.txt\""))
    }

    @Test func keyFilesCanBeDeletedButNotRead() throws {
        let f = try Fixture(); defer { f.clean() }
        // Through the shell's own redirection.
        #expect(try !f.allowed(": < scripts/.env"))
        #expect(try !f.allowed(": < scripts/deploy.pem"))
        #expect(try f.allowed("rm scripts/.env"))
        #expect(!FileManager.default.fileExists(atPath: f.binder.appendingPathComponent("scripts/.env").path))
    }

    @Test func sprawasOwnFilesAreClosed() throws {
        let f = try Fixture(); defer { f.clean() }
        #expect(try f.allowed(": < .sprava/ops.jsonl && ls .sprava >/dev/null"))
        #expect(try !f.allowed("echo x >> .sprava/ops.jsonl"))
        #expect(try !f.allowed("rm .sprava/ops.jsonl"))
        #expect(try !f.allowed("mv .sprava elsewhere"))
        #expect(try !f.allowed("echo x > catalog.json"))
        #expect(try !f.allowed("mv catalog.json c.json"))
        #expect(try !f.allowed("echo x > DASHBOARD.md"))
        // Closing the binder itself would stop Sprava recording the turn, even if a chmod ever ran.
        let chmod = try Fixture(allowing: ["/bin/chmod"]); defer { chmod.clean() }
        #expect(try !chmod.allowed("/bin/chmod 000 ."))
        #expect(try chmod.allowed("mkdir -p sub && /bin/chmod 700 sub"))
        // On a case-insensitive volume, the same files by another spelling.
        #expect(try !f.allowed("echo x > CATALOG.JSON"))
        #expect(try !f.allowed("echo x >> .SPRAVA/ops.jsonl"))
    }

    @Test func nothingOutsideTheBinderIsReachable() throws {
        let f = try Fixture(); defer { f.clean() }
        #expect(try !f.allowed(": < \"$O/private.md\""))
        #expect(try !f.allowed("echo x > \"$O/x\""))
        #expect(try !f.allowed("echo x > /private/tmp/sprava-wall-probe-\(UUID().uuidString)"))
        #expect(try !f.allowed("ls /Users/*/.ssh"))
        // Reads are closed everywhere else too, temporary folders included.
        let stray = URL(fileURLWithPath: "/private/tmp/sprava-wall-\(UUID().uuidString).txt")
        try Data("invented".utf8).write(to: stray); defer { try? FileManager.default.removeItem(at: stray) }
        #expect(try !f.allowed(": < \(stray.path)"))
        #expect(try !f.allowed("ls /private/var/folders"))
        // Homebrew's and the system's application data, as opposed to their programs.
        #expect(try !f.allowed("ls /opt/homebrew/var"))
        #expect(try !f.allowed("ls '/Library/Application Support'"))
        #expect(try !f.allowed("ls /Library/Keychains"))
        // What commands need still reads: the system's own files, and looking up a path.
        #expect(try f.allowed(": < /etc/hosts && pwd && test -d /private/tmp"))
    }

    @Test func aDetachedCommandEndsWithTheTurnAndAnotherSessionsIsLeftAlone() async throws {
        let f = try Fixture(allowing: ["/usr/bin/perl", "/usr/bin/env"]); defer { f.clean() }
        let other = try Fixture(allowing: ["/usr/bin/perl", "/usr/bin/env"]); defer { other.clean() }
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
        let f = try Fixture(proxyPort: proxy.port, allowing: ["/usr/bin/curl"]); defer { f.clean() }
        #expect(try !f.allowed("/bin/bash -c 'exec 3<>/dev/tcp/93.184.216.34/443'"))
        #expect(try !f.allowed("curl -sS -m 4 --noproxy '*' https://example.invalid -o /dev/null"))
        #expect(try f.allowed("/bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/\(proxy.port)'"))
    }

    @Test func aCommandCannotListenForAConnection() throws {
        let f = try Fixture(allowing: ["/usr/bin/perl"]); defer { f.clean() }
        // A listening port would hand a document to whatever connects, past the proxy.
        #expect(try !f.allowed(#"/usr/bin/perl -e 'use Socket; socket(S, PF_INET, SOCK_STREAM, 6) or exit 3; bind(S, pack_sockaddr_in(0, INADDR_ANY)) or exit 4; listen(S, 1) or exit 5; exit 0'"#))
    }

    /// Runs a command with the fixture's folders and no walls, so a refusal inside them is known to come from the walls.
    private func plainly(_ f: Fixture, _ command: String) throws -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh"); task.arguments = ["-c", command]; task.currentDirectoryURL = f.binder
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// A socket in the binder, an IP address or not, hands a document to any program outside the walls that connects.
    @Test func aCommandCannotOpenAUnixSocket() throws {
        let f = try Fixture(); defer { f.clean() }
        let command = #"/usr/bin/perl -e 'use Socket; socket(S, PF_UNIX, SOCK_STREAM, 0) or exit 3; bind(S, pack_sockaddr_un("wall.sock")) or exit 4; listen(S, 1) or exit 5; exit 0'"#
        #expect(try !f.allowed(command))
        #expect(!FileManager.default.fileExists(atPath: f.binder.appendingPathComponent("wall.sock").path))
        #expect(try plainly(f, command))
    }

    /// Another process's System V memory is reached by a number, with no file or service the other walls would see.
    @Test func aCommandCannotAttachAnotherProcesssSharedMemory() throws {
        let f = try Fixture(); defer { f.clean() }
        let id = shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0o600)
        try #require(id >= 0)
        defer { shmctl(id, IPC_RMID, nil) }
        let command = #"/usr/bin/perl -e 'shmread(\#(id), my $bytes, 0, 8) or exit 3; exit 0'"#
        #expect(try !f.allowed(command))
        #expect(try plainly(f, command))
    }

    /// The shell is whole (decisions.md D36): the system's programs run, and the walls are what stop them reaching anything.
    @Test func theSystemsProgramsRunAndTheWallsHoldThem() throws {
        let f = try Fixture(); defer { f.clean() }
        for command in ["mkdir -p a/b", "cp notes.md a/b/c.md", "mv a/b/c.md a/d.md", "ls a", "rm a/d.md", "rmdir a/b",
                        "find . -name notes.md -exec cat {} +", "grep -c . notes.md", "sed -n 1p notes.md", "wc -l notes.md", "head -1 notes.md | cut -c1-4",
                        "/usr/bin/awk 1 notes.md > copy.md && rm copy.md", "for f in notes.md; do /usr/bin/xargs echo < $f; done", "/usr/bin/env /bin/ls", "/usr/bin/sort notes.md",
                        "tar cf x.tar notes.md && rm x.tar", "/usr/bin/perl -e 1", "/usr/sbin/sysctl -n kern.ostype"] {
            #expect(try f.allowed(command), "\(command)")
        }
        for command in ["/usr/bin/open -g .", "echo x | /usr/bin/pbcopy", "/usr/bin/pbpaste", "/usr/bin/security find-generic-password -s invented",
                        "/usr/bin/osascript -e 'tell application \"Finder\" to count of windows'", "/bin/launchctl submit -l invented.wall -- /usr/bin/true", "/usr/bin/crontab /dev/null",
                        "/usr/bin/defaults read com.apple.finder", "/usr/bin/defaults write invented.wall key value",
                        "/usr/sbin/screencapture -x shot.png", "/usr/bin/nc -z -G 2 93.184.216.34 443", "/usr/bin/ssh -o ConnectTimeout=2 -o BatchMode=yes invented@93.184.216.34 true", "/usr/bin/curl -sS -m 3 --noproxy '*' https://93.184.216.34"] {
            #expect(try !f.allowed(command), "\(command)")
        }
    }

    @Test func theInstructionFilesAreThePersonsToWrite() throws {
        let f = try Fixture(); defer { f.clean() }
        for name in ["AGENTS.md", "CLAUDE.md"] {
            try Data("invented".utf8).write(to: f.binder.appendingPathComponent(name))
            #expect(try f.allowed("cat \(name)"))
            #expect(try !f.allowed("echo more >> \(name)"))
            #expect(try !f.allowed("rm \(name)"))
            #expect(try !f.allowed("mv \(name) moved.md"))
        }
    }

    @Test func theCLIIsGivenTheShellWithoutSkippingItsOwnChecks() throws {
        let f = try Fixture(); defer { f.clean() }
        let plan = try ClaudeReadLaunch.plan(program: URL(fileURLWithPath: "/opt/invented/2.1.317"), home: f.root.appendingPathComponent("tools"),
                                             sessionID: UUID(), credential: "invented", policy: "p", reach: .init(folder: f.binder, proxyPort: 4242))
        let allowed = try #require(plan.arguments.firstIndex(of: "--allowedTools")).advanced(by: 1)
        #expect(plan.arguments[allowed].split(separator: ",").map(String.init) == ["Read", "Write", "Edit", "Glob", "Grep", "Bash"])
        #expect(plan.arguments.contains("--restricted") && plan.arguments.contains("dontAsk") && !plan.arguments.contains("--dangerously-skip-permissions"))
        #expect(plan.environment["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == "1")
        #expect(plan.environment["DEVELOPER_DIR"] == "/Library/Developer/CommandLineTools")
    }

    /// A system service works outside the sandbox on the caller's behalf, so the shell reaches only the few it needs.
    @Test func systemServicesAreClosedExceptAShortList() throws {
        let profile = ClaudeReadLaunch.sandbox(home: URL(fileURLWithPath: "/invented/home"), program: URL(fileURLWithPath: "/opt/invented/cli"), reach: .init(folder: URL(fileURLWithPath: "/invented/binder"), proxyPort: 4242), session: UUID())
        #expect(profile.contains("(deny mach-lookup)\n"))
        for name in ["com.apple.coreservices.launchservicesd", "com.apple.coreservices.appleevents", "com.apple.pasteboard.1", "com.apple.cfprefsd.agent", "com.apple.metadata.mds", "com.apple.securityd.xpc", "com.apple.logd", "com.apple.system.logger", "com.apple.diagnosticd"] {
            #expect(!ClaudeReadLaunch.systemServices.contains(name), "\(name)")
        }
    }

    @Test func nothingWrittenOrCopiedCanRun() throws {
        let f = try Fixture(); defer { f.clean() }
        #expect(try !f.allowed("cp /bin/ls ./ls && ./ls"))
        #expect(try !f.allowed("cp /bin/ls \"$HOME/ls\" && \"$HOME/ls\""))
        #expect(try !f.allowed("printf '#!/bin/sh\\nexit 0\\n' > run.sh && chmod +x run.sh && ./run.sh"))
    }

    @Test func aShellCannotLoadALibraryFromTheBinder() throws {
        let f = try Fixture(); defer { f.clean() }
        // A library whose constructor leaves a mark, as an intake attachment could carry one.
        let source = f.binder.appendingPathComponent("payload.c"), mark = f.binder.appendingPathComponent("loaded")
        try Data("#include <stdio.h>\n__attribute__((constructor)) static void run(void) { FILE *f = fopen(\"loaded\", \"w\"); if (f) fclose(f); }\n".utf8).write(to: source)
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        build.arguments = ["-shared", source.path, "-o", f.binder.appendingPathComponent("payload.dylib").path]
        build.standardOutput = FileHandle.nullDevice; build.standardError = FileHandle.nullDevice
        try build.run(); build.waitUntilExit()
        try #require(build.terminationStatus == 0)
        let command = #"enable -f "$B/payload.dylib" payload"#
        // Outside the walls it does load, so its refusal below means something.
        let plain = Process()
        plain.executableURL = URL(fileURLWithPath: "/bin/bash"); plain.arguments = ["-c", command]; plain.currentDirectoryURL = f.binder
        plain.environment = ["B": f.binder.path]
        plain.standardOutput = FileHandle.nullDevice; plain.standardError = FileHandle.nullDevice
        try plain.run(); plain.waitUntilExit()
        try #require(FileManager.default.fileExists(atPath: mark.path))
        try FileManager.default.removeItem(at: mark)
        _ = try f.allowed("/bin/bash -c '\(command)'")
        #expect(!FileManager.default.fileExists(atPath: mark.path))
        _ = try f.allowed(#"DYLD_INSERT_LIBRARIES="$B/payload.dylib" /bin/ls"#)
        #expect(!FileManager.default.fileExists(atPath: mark.path))
    }

    @Test func anotherTerminalsInputCannotBeRead() throws {
        let f = try Fixture(); defer { f.clean() }
        let master = posix_openpt(O_RDWR | O_NOCTTY); defer { close(master) }
        try #require(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0)
        let name = String(cString: ptsname(master))
        let replica = open(name, O_RDWR | O_NOCTTY); defer { close(replica) }
        try #require(replica >= 0)
        // As a person typing into that terminal.
        _ = "invented typed line\n".withCString { write(master, $0, strlen($0)) }
        #expect(try !f.allowed(": < \(name)"))
        #expect(try f.allowed(": < /dev/null && : < /dev/urandom"))
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

    @Test func aLaunchWithToolsHasTheTokenInNoEnvironment() throws {
        let f = try Fixture(); defer { f.clean() }
        let credential = "invented-private-credential"
        let plan = try ClaudeReadLaunch.plan(program: URL(fileURLWithPath: "/opt/invented/2.1.316"), home: f.root.appendingPathComponent("tools"),
                                             sessionID: UUID(), credential: credential, policy: "p", reach: .init(folder: f.binder, proxyPort: 4242))
        // Another process of the same user can read a process's environment, sandboxed or not (kern.procargs2, seen 2026-11-02).
        #expect(plan.environment.values.allSatisfy { !$0.contains(credential) })
        #expect(!plan.arguments.contains { $0.contains(credential) })
        #expect(plan.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(plan.environment["CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"] == "3")
        #expect(plan.secret == credential)
        #expect(!String(reflecting: plan).contains(credential))
    }

    @Test func theSecretArrivesOnItsDescriptorAndNowhereElse() throws {
        let f = try Fixture(); defer { f.clean() }
        let launch = ClaudeReadOnlyTurn.Launch(executable: URL(fileURLWithPath: "/bin/sh"),
                                               arguments: ["-c", "echo \"[$(cat <&3)][$(env | grep -c invented-secret)]\"; exit"],
                                               environment: ["PATH": "/usr/bin:/bin"], directory: f.binder, sessionID: UUID(), secret: "invented-secret")
        let child = try ClaudeTurnProcess(launch, resume: false, sessionArgument: false)
        defer { _ = child.finish() }
        close(child.input); child.input = -1
        var collected = Data(), buffer = [UInt8](repeating: 0, count: 256)
        let flags = fcntl(child.output, F_GETFL); _ = fcntl(child.output, F_SETFL, flags & ~O_NONBLOCK)
        while true {
            let got = read(child.output, &buffer, 256)
            if got <= 0 { break }
            collected.append(contentsOf: buffer.prefix(got))
        }
        #expect(String(decoding: collected, as: UTF8.self) == "[invented-secret][0]\n")
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
        #expect(free.environment["CLAUDE_CODE_OAUTH_TOKEN"] == credential && free.secret == nil)
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

    /// The status line follows the tools, and what it takes from a tool's input is one short line.
    @Test func aTurnsActivityFollowsItsTools() throws {
        var frames = try started(["Bash", "Read", "Edit", "Grep"])
        let id = session.uuidString.lowercased()
        func assistant(_ blocks: String) throws {
            try frames.receive(frame(#"{"type":"assistant","session_id":"\#(id)","parent_tool_use_id":null,"message":{"role":"assistant","content":[\#(blocks)]}}"#))
        }
        #expect(frames.activity.doing == nil && frames.activity.steps == 0)
        try assistant(#"{"type":"tool_use","id":"a","name":"Read","input":{"file_path":"/invented/documents/quote.pdf"}}"#)
        #expect(frames.activity.doing == "Reading \u{201C}quote.pdf\u{201D}" && frames.activity.steps == 1)
        try frames.receive(frame(#"{"type":"user","session_id":"\#(id)","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"x"}]}}"#))
        #expect(frames.activity.doing == "Thinking" && frames.activity.steps == 1)
        try assistant(#"{"type":"tool_use","id":"b","name":"Bash","input":{"command":"rm x","description":"Remove\n\u202Eduplicate   emails"}}"#)
        #expect(frames.activity.doing == "Remove duplicate emails" && frames.activity.steps == 2)
        try assistant(#"{"type":"tool_use","id":"c","name":"Bash","input":{"command":"ls"}}"#)
        #expect(frames.activity.doing == "Running a command")
        try assistant(#"{"type":"tool_use","id":"d","name":"Edit","input":{"file_path":"/invented/a\u202Eb.txt"}}"#)
        #expect(frames.activity.doing == "Changing \u{201C}a_b.txt\u{201D}")
        try assistant(#"{"type":"tool_use","id":"e","name":"Grep","input":{"pattern":"private words"}}"#)
        #expect(frames.activity.doing == "Searching the binder")
        try assistant(#"{"type":"text","text":"the reply"}"#)
        #expect(frames.activity.doing == "Writing" && frames.activity.steps == 5)
        let long = ClaudeTurnActivity.words(tool: "Bash", input: .obj([("description", .str(String(repeating: "é", count: 500)))]))
        #expect(long.count == 91)
        // A name the model made enormous is cut before it is cleaned, so a turn does not stall on it.
        let dots = ContinuousClock().measure {
            #expect(ClaudeTurnActivity.words(tool: "Read", input: .obj([("file_path", .str("/" + String(repeating: ".", count: 2_000_000)))])) == "Reading \u{201C}file\u{201D}")
        }
        #expect(dots < .seconds(2))
        // So is one character carrying 800,000 combining marks, which a character count would let through whole.
        let marks = ContinuousClock().measure {
            _ = ClaudeTurnActivity.words(tool: "Read", input: .obj([("file_path", .str("/a" + String(repeating: "\u{0315}\u{0300}", count: 400_000)))]))
        }
        #expect(marks < .seconds(2))
        #expect(ClaudeTurnActivity.words(tool: "mcp__sprava__update_notes", input: nil) == "Updating the notes")
        #expect(ClaudeTurnActivity.words(tool: "mcp__sprava__search_binder", input: nil) == "Searching the documents")
        #expect(ClaudeTurnActivity.words(tool: "mcp__sprava__add_todo", input: nil) == "Updating the to-dos")
    }

    /// A session runs for a long time, so a kind of frame a newer CLI adds, or a compaction's summary, must not fail its turn.
    @Test func aBinderAgentsLongTurnSurvivesFramesTheContractDoesNotName() throws {
        var frames = try started(["Bash", "Read"])
        let id = session.uuidString.lowercased()
        try frames.receive(frame(#"{"type":"invented_future_frame","session_id":"\#(id)"}"#))
        try frames.receive(frame(#"{"type":"user","session_id":"\#(id)","isCompactSummary":true,"message":{"role":"user","content":"Summary of the invented conversation"}}"#))
        #expect(frames.reply == nil && !frames.ended) // Neither can make a reply; only the result can.
        try frames.receive(frame(#"{"type":"result","subtype":"success","is_error":false,"session_id":"\#(id)","result":"the reply"}"#))
        #expect(frames.reply == "the reply")
        var free = ClaudeReadOnlyFrames(sessionID: session, original: "Tidy")
        try free.receive(frame(#"{"type":"system","subtype":"init","session_id":"\#(id)","tools":[],"mcp_servers":[],"permissionMode":"dontAsk"}"#))
        #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) { try free.receive(frame(#"{"type":"invented_future_frame"}"#)) }
    }

    @Test func noAgentMayRunWithoutTheCLIsChecks() throws {
        let id = session.uuidString.lowercased()
        var withShell = ClaudeReadOnlyFrames(sessionID: session, original: "Tidy", tools: ["Bash"])
        #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) {
            try withShell.receive(frame(#"{"type":"system","subtype":"init","session_id":"\#(id)","tools":["Bash"],"mcp_servers":[],"permissionMode":"bypassPermissions"}"#))
        }
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
