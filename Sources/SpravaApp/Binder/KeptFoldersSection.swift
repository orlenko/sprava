import AppKit
import SpravaKit
import SwiftUI

struct KeptFoldersSection: View {
    let folder: URL
    @State private var paths: [String] = []
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Section("Keep folders as is") {
            Text("Search files in these folders by name and text without making filing cards for them.").foregroundStyle(.secondary)
            ForEach(paths, id: \.self) { path in
                HStack { Text(verbatim: path); Spacer()
                    Button("Remove") { Task { await update("remove", path: path) } }
                        .accessibilityLabel("Stop indexing \(path)")
                }
            }
            Button("Choose Folder…") {
                let picker = NSOpenPanel()
                picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
                picker.directoryURL = folder
                guard picker.runModal() == .OK, let selected = picker.url else { return }
                let prefix = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                let path = selected.resolvingSymlinksInPath().standardizedFileURL.path
                guard path.hasPrefix(prefix) else { error = "Choose a folder inside this binder."; return }
                Task { await update("add", path: String(path.dropFirst(prefix.count))) }
            }
            if let error { Text(verbatim: error).foregroundStyle(.orange) }
        }.disabled(busy).task { await update("list") }
    }

    private func update(_ action: String, path: String? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            var fields: [(String, JSONValue)] = [("kept_folders", .str(action))]
            if let path { fields.append(("path", .str(path))) }
            let result = try await RuntimeClient().command("binder_settings", binder: folder, fields)
            guard let values = result["folders"]?.arrayValue else { throw CocoaError(.fileReadCorruptFile) }
            paths = values.compactMap(\.stringValue); error = nil
        } catch { self.error = "The folder settings could not be checked. \(error)" }
    }
}
