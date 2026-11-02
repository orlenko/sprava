import AppKit
import Combine
import Foundation

/// The app's destination for future New Binder commands. Only the app reads this preference;
/// the runtime still creates each binder through create_binder (code-structure.md rule 5).
@MainActor
final class BinderLocationSettings: ObservableObject {
    static let key = "newBinderParent"
    @Published private(set) var folder: URL?
    @Published private(set) var templateMessage: String?
    private let defaults: UserDefaults
    var chooseFolder: @MainActor (URL?) -> URL? = BinderLocationSettings.folderPanel

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let path = defaults.string(forKey: Self.key), path.hasPrefix("/") {
            folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
    }

    /// General establishes the fresh-install default only after the runtime has created it.
    func useIfUnset(_ parent: URL) {
        guard folder == nil else { return }
        defaults.set(parent.path, forKey: Self.key)
        folder = parent
    }

    func choose() {
        guard let selected = chooseFolder(folder), selected.isFileURL else { return }
        let normalized = selected.standardizedFileURL
        defaults.set(normalized.path, forKey: Self.key)
        folder = normalized
    }

    func openTemplates() async {
        do {
            let result = try await RuntimeClient().global("binder_template_folder")
            guard let path = result["folder"]?.stringValue, path.hasPrefix("/") else { return }
            templateMessage = NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
                ? nil : "The templates folder could not be opened."
        } catch { templateMessage = "Project templates could not be opened: \(error)" }
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
