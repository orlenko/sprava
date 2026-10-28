import Foundation
import SpravaKit
import Testing
@testable import Brains

@Suite struct ClaudeReadLaunchTests {
    func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-claude-launch-\(UUID().uuidString)")
        try AtomicFile.makePrivateFolder(root)
        return root.appendingPathComponent("private-home", isDirectory: true)
    }

    @Test func thePlanHasOnlyExplicitPrivateEnvironmentAndNoShellOrFileTools() throws {
        let folder = try home()
        let plan = try ClaudeReadLaunch.plan(program: URL(fileURLWithPath: "/opt/invented/claude/2.1.304"), home: folder,
                                            sessionID: UUID(), credential: "invented-private-credential", policy: "Canonical fixture policy only.")
        #expect(plan.executable.path == "/usr/bin/sandbox-exec")
        #expect(plan.arguments.contains("--safe-mode") && plan.arguments.contains("--restricted"))
        #expect(plan.arguments.contains("dontAsk") && plan.arguments.contains("{\"mcpServers\":{}}"))
        #expect(!plan.arguments.contains("invented-private-credential"))
        #expect(plan.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "invented-private-credential")
        #expect(plan.environment["HOME"] == folder.resolvingSymlinksInPath().path)
        #expect(plan.environment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] == "1")
        #expect(plan.environment["ANTHROPIC_BASE_URL"] == nil && plan.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(!String(reflecting: plan).contains("invented-private-credential"))
    }

    @Test func cachedCustomizationIsRefusedRatherThanLoaded() throws {
        let folder = try home()
        try AtomicFile.makePrivateFolder(folder)
        try Data("Untrusted cached instructions".utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        #expect(throws: ClaudeReadLaunch.Refused.unsafeHome) {
            try ClaudeReadLaunch.plan(program: URL(fileURLWithPath: "/opt/invented/2.1.304"), home: folder,
                                     sessionID: UUID(), credential: "invented", policy: "Canonical")
        }
    }

    @Test func anUnsignedProgramCannotBecomeAProductionLaunch() throws {
        #expect(throws: ClaudeReadLaunch.Refused.unsupportedInstallation) {
            try ClaudeReadLaunch.prepare(program: URL(fileURLWithPath: "/does-not-exist/2.1.304"), support: home(), connectionID: UUID(),
                                        sessionID: UUID(), credential: "invented", policy: "Canonical", onSpawn: { _ in })
        }
    }

    @Test(arguments: ["/opt/invented/bin/claude", "/opt/invented/versions/9.8.765"])
    func aVerifiedInstallationDoesNotRequireAParticularVersionOrFilename(_ path: String) throws {
        let program = URL(fileURLWithPath: path)
        let hash = try ClaudeReadLaunch.installationHash(program, validatedSignature: { candidate in
            #expect(candidate == program)
            return Data([0x01, 0xab])
        })
        #expect(hash == "01ab")
    }

    @Test func anotherVendorsSignedExecutableIsStillRefused() throws {
        #expect(throws: ClaudeReadLaunch.Refused.unsupportedInstallation) {
            try ClaudeReadLaunch.prepare(program: URL(fileURLWithPath: "/usr/bin/true"), support: home(), connectionID: UUID(),
                                        sessionID: UUID(), credential: "invented", policy: "Canonical", onSpawn: { _ in })
        }
    }

    @Test func sandboxKeepsItsOwnFilesButRefusesOtherUserDataAndChildCommands() throws {
        let folder = try home()
        let locator = Process(), located = Pipe()
        locator.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        locator.arguments = ["--find", "python3"]; locator.standardOutput = located
        try locator.run()
        let raw = located.fileHandleForReading.readDataToEndOfFile()
        locator.waitUntilExit()
        try #require(locator.terminationStatus == 0)
        let wrapper = URL(fileURLWithPath: String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
        // Xcode's python3 launcher spawns the framework interpreter. The profile permits only the
        // actual executable, as production's versioned native Claude binary requires, not that shim.
        let resolve = Process(), resolved = Pipe()
        resolve.executableURL = wrapper
        resolve.arguments = ["-I", "-S", "-c", "import ctypes,os; b=ctypes.create_string_buffer(4096); n=ctypes.CDLL('/usr/lib/libproc.dylib').proc_pidpath(os.getpid(),b,len(b)); print(b.value.decode() if n>0 else '')"]
        resolve.standardOutput = resolved
        try resolve.run()
        let actual = resolved.fileHandleForReading.readDataToEndOfFile()
        resolve.waitUntilExit()
        try #require(resolve.terminationStatus == 0)
        let python = URL(fileURLWithPath: String(decoding: actual, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let plan = try ClaudeReadLaunch.plan(program: python, home: folder, sessionID: UUID(), credential: "invented", policy: "Canonical")
        let own = plan.directory.appendingPathComponent("own.txt")
        try Data("inside".utf8).write(to: own)
        // An invented file in the public workspace, never a live binder or an authentication file.
        let outside = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".scope-canary-\(UUID().uuidString)")
        try Data("outside invented canary".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        func q(_ path: String) -> String { JSONWriter.compact(.str(path)) }
        let script = """
        import json, subprocess
        own = open(\(q(own.path))).read() == 'inside'
        try:
            open(\(q(outside.path))).read()
            outside_blocked = False
        except PermissionError:
            outside_blocked = True
        try:
            subprocess.run(['/bin/sh', '-c', 'exit 0'], check=True)
            commands_blocked = False
        except PermissionError:
            commands_blocked = True
        print(json.dumps([own, outside_blocked, commands_blocked]))
        """
        let task = Process(), output = Pipe(), errors = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        task.arguments = ["-f", plan.directory.appendingPathComponent("app-sandbox.sb").path, python.path, "-I", "-S", "-c", script]
        task.environment = ["HOME": plan.directory.path, "PATH": "/usr/bin:/bin"]
        task.currentDirectoryURL = plan.directory; task.standardOutput = output; task.standardError = errors
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        #expect(task.terminationStatus == 0, "Fixture sandbox failed; diagnostics are structural test setup only: \(String(decoding: diagnostic, as: UTF8.self))")
        #expect(try JSONDecoder().decode([Bool].self, from: data) == [true, true, true])
    }
}
