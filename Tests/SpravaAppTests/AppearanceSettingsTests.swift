import AppKit
import Foundation
@testable import SpravaApp
import Testing

/// Settings › Appearance: Light, Dark or the system's look, kept across launches in the app's own defaults. A private
/// defaults suite per test; the real application's look is never changed.
@MainActor
@Suite struct AppearanceSettingsTests {
    func suite() -> (UserDefaults, String) {
        let name = "sprava-tests-appearance-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func theSystemsLookIsTheDefault() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var applied: [NSAppearance?] = []
        let settings = AppearanceSettings(defaults: defaults, applyTo: { applied.append($0) })
        settings.apply()
        #expect(settings.choice == .system)
        #expect(applied.count == 1 && applied[0] == nil)
    }

    @Test func aChoiceIsAppliedAtOnceAndSurvivesARelaunch() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var applied: [NSAppearance.Name?] = []
        let settings = AppearanceSettings(defaults: defaults, applyTo: { applied.append($0?.name) })
        settings.choice = .dark
        #expect(applied == [.darkAqua])
        // The next launch reads the choice back before its first window.
        let relaunched = AppearanceSettings(defaults: defaults, applyTo: { applied.append($0?.name) })
        #expect(relaunched.choice == .dark)
        relaunched.apply()
        relaunched.choice = .light
        relaunched.choice = .system
        #expect(applied == [.darkAqua, .darkAqua, .aqua, nil])
        #expect(AppearanceSettings(defaults: defaults).choice == .system)
    }

    @Test func anUnknownStoredValueFallsBackToTheSystem() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("sepia", forKey: AppearanceSettings.key)
        #expect(AppearanceSettings(defaults: defaults, applyTo: { _ in }).choice == .system)
    }
}
