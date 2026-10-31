import AppKit
import Combine
import SwiftUI

/// How the app looks: always light, always dark, or as the system is set (the default).
enum Appearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Nil follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The appearance chosen in Settings. It is kept in the app's own defaults, like the Shelf's recent order: state of
/// the app's windows that no binder and no runtime reads (docs/code-structure.md rule 5). Set on the application, so
/// every window, sheet and alert follows it.
@MainActor
final class AppearanceSettings: ObservableObject {
    static let key = "appearance"
    @Published var choice: Appearance {
        didSet {
            defaults.set(choice.rawValue, forKey: Self.key)
            apply()
        }
    }
    private let defaults: UserDefaults
    private let applyTo: @MainActor (NSAppearance?) -> Void

    init(defaults: UserDefaults = .standard,
         applyTo: @escaping @MainActor (NSAppearance?) -> Void = { NSApplication.shared.appearance = $0 }) {
        self.defaults = defaults
        self.applyTo = applyTo
        choice = defaults.string(forKey: Self.key).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    func apply() { applyTo(choice.nsAppearance) }
}

/// The Settings window (⌘,).
struct SettingsView: View {
    @ObservedObject var appearance: AppearanceSettings
    @ObservedObject var binderLocation: BinderLocationSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Binders").font(.headline)
                if let folder = binderLocation.folder {
                    Text(folder.path).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle).help(folder.path)
                } else {
                    Text("Choose a folder for your binders.")
                }
                Button(binderLocation.folder == nil ? "Choose Folder…" : "Change Folder…") {
                    binderLocation.choose()
                }
                Text("New binders are created here. Changing this folder leaves existing binders where they are.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Picker("Appearance", selection: $appearance.choice) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
    }
}
