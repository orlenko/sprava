import SwiftUI

// The app's own menu commands and their shortcuts, in one table so a test can check that none of them collides
// with another or with a shortcut the system's menus already hold.

enum MenuCommand: CaseIterable {
    case newBinder, addFolder, refresh

    struct Shortcut: Hashable {
        let key: Character
        var shift = false
    }

    var title: String {
        switch self {
        case .newBinder: "New Binder…"
        case .addFolder: "Add Folder…"
        case .refresh: "Refresh"
        }
    }

    var shortcut: Shortcut {
        switch self {
        case .newBinder: Shortcut(key: "n", shift: true)
        case .addFolder: Shortcut(key: "o")
        case .refresh: Shortcut(key: "r")
        }
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(shortcut.key), modifiers: shortcut.shift ? [.command, .shift] : .command)
    }

    /// Command and Shift-Command shortcuts held by the menus macOS and SwiftUI give a WindowGroup app: File (New
    /// Window ⌘N, Close ⌘W), the app menu, Edit with its Find and Spelling items, Window, and Help.
    static let reserved: Set<Shortcut> = [
        Shortcut(key: "n"), Shortcut(key: "w"), Shortcut(key: "q"), Shortcut(key: "h"), Shortcut(key: ","),
        Shortcut(key: "z"), Shortcut(key: "z", shift: true), Shortcut(key: "x"), Shortcut(key: "c"),
        Shortcut(key: "v"), Shortcut(key: "a"), Shortcut(key: "f"), Shortcut(key: "g"), Shortcut(key: "g", shift: true),
        Shortcut(key: "e"), Shortcut(key: "j"), Shortcut(key: ":"), Shortcut(key: ";"), Shortcut(key: "m"),
        Shortcut(key: "\\", shift: true), Shortcut(key: "/", shift: true),
    ]
}

extension View {
    func menuShortcut(_ command: MenuCommand) -> some View {
        keyboardShortcut(command.keyboardShortcut)
    }
}
