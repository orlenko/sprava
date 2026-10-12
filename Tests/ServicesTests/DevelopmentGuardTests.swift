import BinderFormat
import Darwin
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The development commands' safety checks: their own state folder, and never a live binder (one lifeproj's
/// registry lists, one on the installed app's Shelf, or one the installed app owns). Temporary folders and invented
/// binders only.
@Suite(.serialized) struct DevelopmentGuardTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-dev-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func developmentStateIsNeverTheInstalledApps() {
        #expect(DevelopmentSupport.directory(environment: ["SPRAVA_SUPPORT_DIR": "/Invented/Sprava"]).path == "/Invented/Sprava-dev")
        #expect(DevelopmentSupport.directory(environment: [:]).lastPathComponent == "Sprava-dev")
    }

    @Test func developmentCommandsRefuseShelfAndOwnedBinders() throws {
        let root = try folder()
        let production = root.appendingPathComponent("Support", isDirectory: true)
        let registry = root.appendingPathComponent("no-registry.toml")
        let binder = try makeTeka(fixture: "lifeproj-v2-live")
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production) == nil)

        // On the installed app's Shelf (a binder Sprava created is there, not in lifeproj's registry).
        try ShelfStore(supportDirectory: production).add(binder)
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production)?.contains("Shelf") == true)
        try ShelfStore(supportDirectory: production).remove(binder)

        // Owned by the installed app.
        let installed = try DeviceID.load(support: production)
        let owner = binder.appendingPathComponent(".sprava/owner.json")
        try FileManager.default.createDirectory(at: owner.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"device":"\#(installed)"}"#.utf8).write(to: owner)
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production)?.contains("installed Sprava") == true)
        // Owned by the development identity: allowed.
        try Data(#"{"device":"\#(UUID().uuidString.lowercased())"}"#.utf8).write(to: owner)
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production) == nil)

        // A Shelf that cannot be read might list it.
        try Data("not json".utf8).write(to: production.appendingPathComponent("shelf.json"))
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production)?.contains("cannot be read") == true)
    }

    /// An owner record that is a FIFO, a link or too large is neither waited on nor followed: the owner is unknown
    /// and development commands refuse.
    @Test func anOwnerRecordThatCannotBeReadRefusesWithoutHanging() throws {
        let root = try folder()
        let production = root.appendingPathComponent("Support", isDirectory: true)
        let registry = root.appendingPathComponent("no-registry.toml")
        let binder = try makeTeka(fixture: "lifeproj-v2-live")
        let owner = binder.appendingPathComponent(".sprava/owner.json")
        try FileManager.default.createDirectory(at: owner.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: owner)
        #expect(mkfifo(owner.path, 0o600) == 0)
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production)?
            .contains("owner record") == true)
        try FileManager.default.removeItem(at: owner)
        try Data((#"{"device":"invented","padding":""# + String(repeating: "x", count: 70_000) + #""}"#).utf8).write(to: owner)
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production)?
            .contains("owner record") == true)
    }

    @Test func anUnreadableRegistryStopsDevelopmentCommands() throws {
        let dir = try folder()
        let binder = dir.appendingPathComponent("estate-example", isDirectory: true)
        let registry = dir.appendingPathComponent("registry.toml")
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: dir.appendingPathComponent("Support")) == nil)
        try Data([0x5B, 0xFF, 0xFE, 0x5D]).write(to: registry)
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: dir.appendingPathComponent("Support"))?
            .contains("cannot be read") == true)
    }
}
