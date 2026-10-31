import AppKit
import Foundation
@testable import SpravaApp
import Testing

/// Invented destinations and a private defaults suite. No real folder picker or runtime is opened.
@MainActor
@Suite struct BinderLocationSettingsTests {
    func defaults() -> (UserDefaults, String) {
        let name = "sprava-tests-binder-location-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func firstUseOpensSettingsWithoutAskingForANameOrCreatingABinder() async throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = BinderLocationSettings(defaults: defaults)
        let runtime = StandInRuntime()
        let model = ShelfModel(support: try temporaryFolder(), client: runtime.client)
        model.binderParent = { settings.folder }
        var opened = 0
        var asked = false
        model.openSettings = { opened += 1 }
        model.askForBinder = { _, _, _ in asked = true; return ("blank", "garden-shed", "") }
        await model.startNewBinder()
        #expect(opened == 1 && !asked && runtime.sent.isEmpty)
        #expect(model.note == "Choose your binders folder in Settings, then create a binder.")
        #expect(!model.creatingBinder)
    }

    @Test func oneFolderChoiceServesMultipleBindersAndSurvivesRelaunch() async throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let parent = try temporaryFolder()
        let settings = BinderLocationSettings(defaults: defaults)
        var choices = 0
        settings.chooseFolder = { _ in choices += 1; return parent }
        settings.choose()
        let relaunched = BinderLocationSettings(defaults: defaults)
        #expect(relaunched.folder == parent.standardizedFileURL)
        let runtime = StandInRuntime()
        runtime.answers["create_binder"] = { _ in #"{"ok":true,"binder":null}"# }
        let model = ShelfModel(support: try temporaryFolder(), client: runtime.client)
        model.binderParent = { relaunched.folder }
        var shown: [URL] = []
        var names = ["Garden Shed", "Kitchen Reno"]
        model.askForBinder = { _, _, destination in
            shown.append(destination)
            return ("blank", names.removeFirst(), "")
        }
        await model.startNewBinder()
        await model.startNewBinder()
        #expect(choices == 1 && shown == [parent, parent])
        #expect(runtime.sent.map { $0["parent"]?.stringValue } == [parent.path, parent.path])
        #expect(runtime.sent.map { $0["name"]?.stringValue } == ["garden-shed", "kitchen-reno"])
        #expect(model.note == nil)
    }

    @Test func changingOrCancellingTheLocationNeverCreatesOrMovesABinder() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = BinderLocationSettings(defaults: defaults)
        settings.chooseFolder = { _ in nil }
        settings.choose()
        #expect(settings.folder == nil)
        let first = try temporaryFolder()
        let existing = first.appendingPathComponent("garden-shed")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        settings.chooseFolder = { _ in first }
        settings.choose()
        settings.chooseFolder = { current in
            #expect(current == first)
            return nil
        }
        settings.choose()
        #expect(settings.folder == first)
        let second = try temporaryFolder()
        settings.chooseFolder = { _ in second }
        settings.choose()
        #expect(BinderLocationSettings(defaults: defaults).folder == second)
        #expect(FileManager.default.fileExists(atPath: existing.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.path).isEmpty)
    }

    @Test(arguments: ["", "  \n "])
    func anEmptyNameCannotCreateAPlaceholderBinder(typed: String) async throws {
        let runtime = StandInRuntime()
        let model = ShelfModel(support: try temporaryFolder(), client: runtime.client)
        let parent = try temporaryFolder()
        model.binderParent = { parent }
        model.askForBinder = { _, _, _ in ("blank", typed, "") }
        await model.startNewBinder()
        #expect(runtime.sent.isEmpty && model.note == "The binder was not created: enter a name.")
    }

    @Test func createIsExplicitAndDisabledUntilTheNameAndYearAreReady() {
        let parent = URL(fileURLWithPath: "/Invented/Binders")
        let (alert, fields) = ShelfModel.binderDialog(empty: nil, year: 2026, parent: parent)
        let create = alert.buttons[0]
        #expect(create.title == "Create Binder" && !create.isEnabled)
        #expect(fields.name.stringValue.isEmpty)
        #expect(alert.informativeText.contains(parent.path))
        fields.name.stringValue = "Garden Shed"
        fields.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields.name))
        #expect(create.isEnabled)
        fields.picker.selectItem(at: 1) // A tax year.
        fields.templateChanged()
        fields.year.stringValue = "20"
        fields.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields.year))
        #expect(!create.isEnabled)
        fields.year.stringValue = "2025"
        fields.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields.year))
        #expect(create.isEnabled && fields.name.stringValue == "Garden Shed")
    }
}
