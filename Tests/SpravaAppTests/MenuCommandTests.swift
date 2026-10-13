@testable import SpravaApp
import SwiftUI
import Testing

@Suite struct MenuCommandTests {
    @Test func newBinderDoesNotTakeNewWindowsCommandN() {
        #expect(MenuCommand.newBinder.shortcut != MenuCommand.Shortcut(key: "n"))
        #expect(MenuCommand.newBinder.shortcut == MenuCommand.Shortcut(key: "n", shift: true))
        #expect(MenuCommand.newBinder.keyboardShortcut.modifiers == [.command, .shift])
    }

    @Test func noShortcutCollidesWithAnotherOrWithTheSystemMenus() {
        let shortcuts = MenuCommand.allCases.map(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
        for command in MenuCommand.allCases {
            #expect(!MenuCommand.reserved.contains(command.shortcut), "\(command.title) uses a reserved shortcut")
        }
    }
}
