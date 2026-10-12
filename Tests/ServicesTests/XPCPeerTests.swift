import Darwin
import Foundation
import Security
@testable import Services
import Testing

/// Who may connect to the runtime (architecture 2.1), and where an app request runs. The signed programs are
/// copies of system tools in a temporary folder, signed ad hoc for the test.
@Suite struct XPCPeerTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-xpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func signedCopy(of tool: String, identifier: String, in dir: URL) throws -> URL {
        let copy = dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: tool), to: copy)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", "--identifier", identifier, copy.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        return copy
    }

    func satisfies(_ url: URL, _ requirement: String) throws -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        try #require(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess)
        try #require(SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess)
        return SecStaticCodeCheckValidity(code!, [], req) == errSecSuccess
    }

    @Test func onlyTheAppsOwnCodeMeetsTheRequirement() throws {
        let dir = try folder()
        let app = try signedCopy(of: "/usr/bin/true", identifier: XPCNames.appIdentifier, in: dir)
        let pinned = try XPCPeer.app(at: app)
        #expect(pinned.identifier == XPCNames.appIdentifier && pinned.cdhash.count == 40)
        let requirement = XPCPeer.requirement(for: pinned)
        #expect(try satisfies(app, requirement))
        // Another program signed under the app's identifier: accepted by an identifier-only rule, not by this one.
        let impostor = try signedCopy(of: "/bin/echo", identifier: XPCNames.appIdentifier, in: dir)
        #expect(try satisfies(impostor, #"identifier "ca.orlenko.sprava""#))
        #expect(try !satisfies(impostor, requirement))
        // A bundle signed under another identifier pins nothing: no peer is admitted.
        let other = try signedCopy(of: "/usr/bin/true", identifier: "org.example.other", in: dir)
        #expect(throws: XPCPeer.Unverifiable.self) { try XPCPeer.app(at: other) }
        #expect(throws: XPCPeer.Unverifiable.self) { try XPCPeer.app(at: dir.appendingPathComponent("missing")) }
    }

    @Test func thePeerMustBeTheSameUserRunningTheAppsExecutable() throws {
        let dir = try folder()
        let app = try XPCPeer.app(at: try signedCopy(of: "/usr/bin/true", identifier: XPCNames.appIdentifier, in: dir))
        #expect(XPCPeer.accepts(peerUID: getuid(), peerPath: app.executable.path, app: app))
        #expect(!XPCPeer.accepts(peerUID: getuid() + 1, peerPath: app.executable.path, app: app))
        #expect(!XPCPeer.accepts(peerUID: getuid(), peerPath: "/tmp/elsewhere/SpravaApp", app: app))
        #expect(!XPCPeer.accepts(peerUID: getuid(), peerPath: nil, app: app))
        // The peer's path comes from its process; this test's own is an existing file.
        let mine = try #require(XPCPeer.path(of: getpid()))
        #expect(FileManager.default.fileExists(atPath: mine))
    }
}

/// Binder commands run one at a time on the command queue; backup repository work on a queue of its own.
@Suite struct RequestQueuesTests {
    @Test func aStalledPeekLeavesTheCommandQueueFree() throws {
        let watch = WatchBox(budgets: RequestQueues.budgets)
        let queues = RequestQueues(watch: watch)
        let release = DispatchSemaphore(value: 0)
        let pingDone = DispatchSemaphore(value: 0)
        let peekDone = DispatchSemaphore(value: 0)
        queues.submit(#"{"command":"peek","backup_id":"x","path":"a.pdf"}"#, handle: { _ in
            release.wait()
            return #"{"ok":true}"#
        }) { _, command, _ in
            #expect(command == "peek")
            peekDone.signal()
        }
        queues.submit(#"{"command":"ping"}"#, handle: { _ in #"{"ok":true}"# }) { _, _, _ in pingDone.signal() }
        #expect(pingDone.wait(timeout: .now() + 5) == .success)
        // The stalled request is named to the watchdog while it runs.
        #expect(watch.runningFor("app_backup_request") != nil)
        #expect(watch.runningFor("app_request") == nil)
        release.signal()
        #expect(peekDone.wait(timeout: .now() + 5) == .success)
        queues.repository.sync {}
        #expect(watch.runningFor("app_backup_request") == nil)
        #expect(RequestQueues.repositoryCommands == ["peek", "backup_setup", "backup_second"])
    }

    @Test func aRequestWithoutACommandIsNamedAndRunsOnTheCommandQueue() {
        #expect(RequestQueues.command(of: "not json") == "?")
        #expect(RequestQueues.command(of: #"{"command":"approve"}"#) == "approve")
        let queues = RequestQueues(watch: nil)
        let done = DispatchSemaphore(value: 0)
        queues.submit("not json", handle: { _ in
            dispatchPrecondition(condition: .onQueue(queues.commands))
            return "{}"
        }) { _, command, _ in
            #expect(command == "?")
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
    }
}
