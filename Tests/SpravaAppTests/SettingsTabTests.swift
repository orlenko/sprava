import AppKit
import BinderFormat
import Foundation
import Shelf
@testable import SpravaApp
import SpravaTestSupport
import SwiftUI
import Testing

/// Backup and Assistant live in the Settings window (decisions.md D37), so what used to go to their pages opens the tab.
@MainActor
@Suite struct SettingsTabTests {
    @Test func openingATabShowsItEvenIfSettingsWasOnAnother() throws {
        let model = ShelfModel(support: try temporaryFolder(), client: StandInRuntime().client, deadline: ManualDeadlines().deadline)
        var opened = 0
        model.openSettings = { opened += 1 }
        model.openSettings(.assistant)
        #expect(model.settingsTab == .assistant && opened == 1)
        model.openSettings(.backup)
        #expect(model.settingsTab == .backup && opened == 2)
    }

    /// The pages are gone from the main window: a selection naming one falls back to Today.
    @Test func theMainWindowHasOnlyItsOwnPages() async throws {
        let support = try temporaryFolder()
        try ShelfStore(supportDirectory: support).add(try makeTeka(fixture: "sprava-v0", folderName: "tax-2026"))
        let model = ShelfModel(support: support, client: StandInRuntime().client, deadline: ManualDeadlines().deadline)
        model.selection = URL(string: "sprava:backup")
        await model.refreshAndWait()
        #expect(model.selection == todosSelection)
    }

    /// The Backup tab has a fixed width: a long binder name must not push Run out of it.
    @Test func aLongBinderNameDoesNotWidenTheDrillRow() throws {
        // A binder's name comes from its catalog, not its folder.
        let folder = try makeTeka(fixture: "sprava-v0")
        let catalog = folder.appendingPathComponent("catalog.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        var meta = try #require(json["meta"] as? [String: Any])
        meta["name"] = String(repeating: "Long binder name ", count: 12)
        json["meta"] = meta
        try JSONSerialization.data(withJSONObject: json).write(to: catalog)
        let row = ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))
        #expect(row.name.count > 100)
        let picker = DrillPicker(rows: [row], chosen: .constant(folder))
        #expect(NSHostingController(rootView: picker).sizeThatFits(in: NSSize(width: 10, height: 10)).width <= 280)
    }

    /// So does asking for a template when there is none.
    @Test func noTemplatesGoesToGeneral() async throws {
        let runtime = StandInRuntime()
        runtime.answers["binder_templates"] = { _ in #"{"ok":true,"templates":[]}"# }
        let model = ShelfModel(support: try temporaryFolder(), client: runtime.client, deadline: ManualDeadlines().deadline)
        let parent = try temporaryFolder()
        model.binderParent = { parent }
        model.settingsTab = .backup
        var opened = 0
        model.openSettings = { opened += 1 }
        await model.startNewBinder()
        #expect(model.note == "Add a project template in Settings before creating a binder.")
        #expect(model.settingsTab == .general && opened == 1)
    }

    /// A binder with no folder chosen goes to General, even when Settings was last left on another tab.
    @Test func aMissingBinderFolderGoesToGeneral() async throws {
        let model = ShelfModel(support: try temporaryFolder(), client: StandInRuntime().client, deadline: ManualDeadlines().deadline)
        model.binderParent = { nil }
        model.settingsTab = .backup
        var opened = 0
        model.openSettings = { opened += 1 }
        await model.startNewBinder()
        #expect(model.settingsTab == .general && opened == 1)
    }
}
