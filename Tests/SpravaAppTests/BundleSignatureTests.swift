import Foundation
@testable import SpravaApp
import Testing

/// Setting up background work checks the app's own signature first: a bundle whose executables are signed but whose
/// resources (the LaunchAgent plists) are not sealed is what a build that stopped halfway leaves, and SMAppService
/// refuses it with a raw -67056. The bundles here are invented, in a temporary folder; nothing is registered.
@Suite struct BundleSignatureTests {
    func codesign(_ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
    }

    /// An app bundle laid out like Sprava's, its executable signed alone as the linker signs it.
    func unsealedBundle() throws -> URL {
        let app = try temporaryFolder().appendingPathComponent("Example.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents")
        for dir in ["MacOS", "Library/LaunchAgents"] {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let info: [String: Any] = ["CFBundleExecutable": "Example", "CFBundleIdentifier": "org.example.app",
                                   "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let agent: [String: Any] = ["Label": "org.example.agent", "BundleProgram": "Contents/MacOS/Example"]
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Library/LaunchAgents/org.example.agent.plist"))
        // Signed outside the bundle: codesign given a bundle's main executable signs the whole bundle.
        let loose = app.deletingLastPathComponent().appendingPathComponent("Example")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: loose)
        try codesign(["--force", "--sign", "-", loose.path])
        try FileManager.default.moveItem(at: loose, to: contents.appendingPathComponent("MacOS/Example"))
        return app
    }

    @Test func aBundleWhoseResourcesAreNotSealedIsNamedBeforeRegistering() throws {
        let app = try unsealedBundle()
        let problem = try #require(BundleSignature.problem(at: app))
        #expect(problem.hasPrefix(BundleSignature.problemText) && problem.contains("-67056"))
    }

    @Test func aWholeSignatureHasNoProblemAndAChangedPlistHasOne() throws {
        let app = try unsealedBundle()
        try codesign(["--force", "--sign", "-", app.path])
        #expect(BundleSignature.problem(at: app) == nil)
        let plist = app.appendingPathComponent("Contents/Library/LaunchAgents/org.example.agent.plist")
        try Data("<plist/>".utf8).write(to: plist)
        #expect(BundleSignature.problem(at: app) != nil)
        #expect(BundleSignature.problem(at: app.deletingLastPathComponent().appendingPathComponent("Missing.app")) != nil)
    }

    @Test func aSignatureRefusalFromRegisterIsSaidPlainly() {
        let refused = NSError(domain: "SMAppServiceErrorDomain", code: 3, userInfo: [NSLocalizedDescriptionKey:
            "The operation couldn't be completed. Codesigning failure loading plist: org.example.agent.plist code: -67056"])
        #expect(BundleSignature.registerFailure(refused).hasPrefix(BundleSignature.problemText))
        #expect(BundleSignature.registerFailure(refused).contains("-67056"))
        let other = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        #expect(BundleSignature.registerFailure(other) == "Could not turn on background work: Operation not permitted")
    }
}
