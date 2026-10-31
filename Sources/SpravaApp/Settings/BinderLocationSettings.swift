import AppKit
import Combine
import Foundation

/// The app's destination for future New Binder commands. Only the app reads this preference;
/// the runtime still creates each binder through create_binder (code-structure.md rule 5).
@MainActor
final class BinderLocationSettings: ObservableObject {
    static let key = "newBinderParent"
    @Published private(set) var folder: URL?
    private let defaults: UserDefaults
    var chooseFolder: @MainActor (URL?) -> URL? = BinderLocationSettings.folderPanel

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let path = defaults.string(forKey: Self.key), path.hasPrefix("/") {
            folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
    }

    func choose() {
        guard let selected = chooseFolder(folder), selected.isFileURL else { return }
        let normalized = selected.standardizedFileURL
        defaults.set(normalized.path, forKey: Self.key)
        folder = normalized
    }

    static func folderPanel(current: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = current
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder for new binders."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
