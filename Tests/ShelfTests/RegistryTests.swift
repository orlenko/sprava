import Foundation
@testable import Shelf
import SpravaTestSupport
import Testing

@Suite struct RegistryTests {
    @Test func readsProjectsAndArchived() {
        let toml = """
        # cmirror configuration
        identity_file = "~/.config/age/key.txt"

        [lifeproj]
        teka_home = "~/binders"

        [projects.kitchen-reno]
        working_dir = "~/binders/kitchen-reno"
        encrypted_dir = "/tmp/enc/kitchen-reno"

        [projects."tax-2026"]
        working_dir = '/Users/example/binders/tax-2026'

        [archived.estate-example]
        working_dir = "~/binders/estate-example"
        """
        let registry = LifeprojRegistry.parse(toml)
        #expect(registry.entries.map(\.name) == ["kitchen-reno", "tax-2026", "estate-example"])
        #expect(registry.entries[1].workingDir == "/Users/example/binders/tax-2026")
        #expect(registry.entries[2].archived)
        let rows = Shelf.rows(registry: registry, picked: [])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.teka.state == .notATeka })
    }

    @Test func shelfStoreKeepsPickedFoldersOutsideBinders() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-support-\(UUID().uuidString)")
        let store = ShelfStore(supportDirectory: support)
        let folder = try makeTeka(fixture: "sprava-v0")
        try store.add(folder)
        try store.add(folder)
        #expect(store.pickedFolders().map(\.standardizedFileURL) == [folder.standardizedFileURL])
        let rows = Shelf.rows(registry: nil, picked: store.pickedFolders())
        #expect(rows.first?.stateLabel == "not yet adopted")
        try store.remove(folder)
        #expect(store.pickedFolders().isEmpty)
    }

    /// lifeproj's registry stays off the Shelf unless the person turns it on; adding a folder keeps the choice.
    @Test func theRegistryIsOffTheShelfUnlessTurnedOn() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-support-\(UUID().uuidString)")
        let store = ShelfStore(supportDirectory: support)
        let folder = try makeTeka(fixture: "sprava-v0")
        try store.add(folder)
        #expect(!store.showsRegistry)
        #expect(try store.registryForShelf() == nil)
        #expect(store.rows().map(\.source) == [.picked])
        try Data(#"{"schemaVersion":1,"folders":[],"showRegistry":true}"#.utf8).write(to: store.file)
        try store.add(folder)
        #expect(store.showsRegistry)
    }

    @Test func theBinderOpenedLastIsOnTopAndOthersSink() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-support-\(UUID().uuidString)")
        let recent = RecentBinders(supportDirectory: support)
        let a = try makeTeka(fixture: "sprava-v0"), b = try makeTeka(fixture: "sprava-v0"), c = try makeTeka(fixture: "sprava-v0")
        let rows = Shelf.rows(registry: nil, picked: [a, b, c])
        let t = Date(timeIntervalSince1970: 1_791_360_000)
        recent.touch(a, now: t)
        recent.touch(c, now: t.addingTimeInterval(60))
        let ordered = RecentBinders.order(rows, opened: recent.opened()).map(\.folder.standardizedFileURL)
        #expect(ordered == [c, a, b].map(\.standardizedFileURL))
        recent.touch(b, now: t.addingTimeInterval(120))
        #expect(RecentBinders.order(rows, opened: recent.opened()).first?.folder.standardizedFileURL == b.standardizedFileURL)
    }
}
