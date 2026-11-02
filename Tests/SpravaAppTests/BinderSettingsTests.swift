@testable import SpravaApp
import AppKit
import SpravaKit
import SwiftUI
import Testing

@MainActor
@Suite struct BinderSettingsTests {
    @Test func settingsOpenPerBinderAndCloseAgain() {
        let selection = BinderWorkspaceSelection()
        let one = URL(fileURLWithPath: "/invented/kitchen-reno"), other = URL(fileURLWithPath: "/invented/garden")
        #expect(!selection.showsSettings(one))
        selection.toggleSettings(one)
        #expect(selection.showsSettings(one) && !selection.showsSettings(other))
        selection.toggleSettings(one)
        #expect(!selection.showsSettings(one))
    }

    final class Draft: ObservableObject {
        nonisolated(unsafe) static var made = 0
        init() { Self.made += 1 }
    }
    struct Holder: View {
        @StateObject private var draft = Draft()
        var body: some View { Text("Half filled in") }
    }
    final class Shown: ObservableObject { @Published var settings = false }
    struct Layers: View {
        @ObservedObject var shown: Shown
        var body: some View { BinderPageLayers(settingsShown: shown.settings) { Holder() } settings: { Holder() } }
    }

    /// Closing the settings once dropped an email setup half filled in, kept in a model the page owned.
    @Test func goingBetweenTheWorkingPageAndItsSettingsKeepsWhatEachHolds() {
        Draft.made = 0
        let shown = Shown()
        let host = NSHostingView(rootView: Layers(shown: shown).frame(width: 400, height: 300))
        func settle() { for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.03)) } }
        settle()
        #expect(Draft.made == 2)
        for value in [true, false, true, false] { shown.settings = value; settle() }
        #expect(Draft.made == 2)
    }

    @Test func theSettingsPageDoesNotRaiseTheWindowsMinimumHeight() {
        let page = BinderSettingsPage(actions: BinderActions(), folder: URL(fileURLWithPath: "/invented/kitchen-reno"),
                                      today: CalendarDate(year: 2031, month: 2, day: 3)!, writable: true, conversation: nil, reload: {})
        let host = NSHostingView(rootView: page.frame(minWidth: 500, minHeight: 480))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        #expect(host.fittingSize.height <= 480)
    }
}
