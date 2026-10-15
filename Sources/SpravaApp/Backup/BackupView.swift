import AppKit
import Combine
import SpravaKit
import SwiftUI

/// The Backup page (docs/backup.md §4, §5, §7): setting up the mirror and its key, the second backup, and what the
/// runtime reports. Everything goes through the runtime's backup commands; slow work runs there and this page reads
/// its status again. Restore, peek and offloaded binders join with their commands.
@MainActor
final class BackupModel: ObservableObject, RuntimePage {
    struct Line: Identifiable, Equatable { let id: Int; let name: String; let at: String?; let error: String? }
    struct Request: Identifiable, Equatable { let id: String; let kind: String; let state: String; let message: String? }

    /// The default mirror, the same folder as `Backup.defaultPrimary`: the app does not link the Backup target.
    static var defaultPrimary: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Sprava Backup", isDirectory: true).path
    }

    /// Nil until the runtime has answered once: the page offers no setup before it knows backup is not set up.
    @Published var configured: Bool?
    @Published var primary = BackupModel.defaultPrimary
    @Published var secondPath: String?
    @Published var upload: String?
    @Published var lastCheck: String?
    @Published var lastDrill: String?
    @Published var stateError: String?
    @Published var lines: [Line] = []
    @Published var requests: [Request] = []
    /// A key the runtime made and holds as pending: shown once, never saved by the app.
    @Published var newKey: String?
    /// A key made earlier is waiting for its confirmation (the app was closed after it was shown).
    @Published var pendingKey = false
    @Published var typedKey = ""
    @Published var iCloudKeychain = false
    @Published var working = false
    @Published var message: String? { didSet { readFoundNoRuntime = false } }
    var readFoundNoRuntime = false
    let client: RuntimeClient

    init(client: RuntimeClient = RuntimeClient()) {
        self.client = client
        client.clearsNotRunning(self)
    }

    func load() async {
        do {
            let r = try await client.global("backup_status", timeout: 10)
            configured = r["configured"] == .bool(true)
            if let p = r["primary"]?.stringValue { primary = p }
            secondPath = r["second_path"]?.stringValue
            pendingKey = r["pending_key"] == .bool(true)
            upload = r["upload"]?.stringValue
            lastCheck = r["last_check"]?.stringValue
            lastDrill = r["last_drill"]?.stringValue
            stateError = r["state_error"]?.stringValue
            lines = (r["binders"]?.arrayValue ?? []).enumerated().map { i, b in
                Line(id: i, name: b["name"]?.stringValue ?? "?", at: b["at"]?.stringValue, error: b["error"]?.stringValue)
            }
            requests = (r["requests"]?.arrayValue ?? []).compactMap { q in
                guard let id = q["id"]?.stringValue else { return nil }
                return Request(id: id, kind: q["kind"]?.stringValue ?? "", state: q["state"]?.stringValue ?? "",
                               message: q["message"]?.stringValue)
            }
        } catch {
            readFailed("Backup status could not be read: \(error)", error)
        }
    }

    /// Step 1 of setup: the runtime makes a key and keeps it pending until it is typed back.
    func createKey() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            newKey = try await client.global("backup_new_key")["key"]?.stringValue
            typedKey = ""
            message = nil
        } catch {
            message = "No key was made: \(error)"
        }
    }

    /// Step 2: the key typed back (or one from an earlier setup) and the mirror. The runtime checks the folder is
    /// in iCloud and makes the repository, which can take a few minutes.
    func setUp() async {
        guard !working, !typedKey.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            _ = try await client.global("backup_setup", [("key", .string(typedKey)), ("primary", .string(primary)),
                                                          ("icloud_keychain", .bool(iCloudKeychain))], timeout: 300)
            newKey = nil
            typedKey = ""
            message = "Backup is set up. The first backups start within the hour."
        } catch {
            message = "Backup is not set up: \(error)"
        }
        await load()
    }

    func setSecond(_ path: String) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            _ = try await client.global("backup_second", [("folder", .string(path))], timeout: 300)
            message = "The second backup is set."
        } catch {
            message = "The second backup was not set: \(error)"
        }
        await load()
    }

    static func chooseFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

struct BackupView: View {
    @ObservedObject var model: BackupModel

    var body: some View {
        List {
            if let message = model.message { Text(message).foregroundStyle(.orange) }
            if let error = model.stateError { Text("Backup records cannot be read: \(error)").foregroundStyle(.red) }
            switch model.configured {
            case nil: Text("Asking Sprava's background part…").foregroundStyle(.secondary)
            case false?: setup
            case true?: status
            }
            if !model.requests.isEmpty {
                Section("In progress and recent") {
                    ForEach(model.requests) { r in
                        HStack(alignment: .top) {
                            Text(r.kind.replacingOccurrences(of: "_", with: " ")).frame(width: 90, alignment: .leading)
                            Text(r.state.replacingOccurrences(of: "_", with: " "))
                                .foregroundStyle(r.state == "failed" ? .red : .secondary)
                            if let m = r.message { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                        }
                    }
                }
            }
        }
        .disabled(model.working)
        .task {
            while !Task.isCancelled {
                if !model.working { await model.load() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder var setup: some View {
        Section("Set up backup") {
            Text("Sprava keeps an encrypted copy of every binder in a folder of your iCloud Drive. Only your key opens it.")
            HStack {
                Text(model.primary).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { if let p = BackupModel.chooseFolder(prompt: "Use for Backup") { model.primary = p } }
            }
            Toggle("Also keep the key in iCloud Keychain (recovery on a new Mac without typing it; less private)",
                   isOn: $model.iCloudKeychain)
            if let key = model.newKey {
                Text("Your backup key. Save it where you keep such things, such as a password manager. Without it the backup cannot be opened.")
                HStack {
                    Text(key).font(.title3.monospaced()).textSelection(.enabled)
                    Button("Copy") { _ = ProtectedClipboard.copy(key, lifetime: .seconds(120)) }
                }
                TextField("Type the key back to confirm you saved it", text: $model.typedKey).textFieldStyle(.roundedBorder)
                Button("Set Up Backup") { Task { await model.setUp() } }.disabled(model.typedKey.isEmpty)
            } else {
                if model.pendingKey {
                    Text("A key was made earlier and not yet confirmed. Type that key below, or create a new one.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Create a Key") { Task { await model.createKey() } }
                    Text(model.pendingKey ? "or type the key shown earlier:" : "or, with a key from an earlier setup:")
                        .foregroundStyle(.secondary)
                    TextField("paste it here", text: $model.typedKey).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Button("Use It") { Task { await model.setUp() } }.disabled(model.typedKey.isEmpty)
                }
            }
            if model.working { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder var status: some View {
        Section("Backup") {
            LabeledContent("Mirror", value: model.primary)
            LabeledContent("iCloud", value: model.upload ?? "not checked yet")
            LabeledContent("Last check", value: model.lastCheck.map { String($0.prefix(16)) } ?? "not yet")
            LabeledContent("Last restore drill", value: model.lastDrill.map { String($0.prefix(16)) } ?? "never")
            HStack {
                Text("Second backup").frame(width: 120, alignment: .leading)
                Text(model.secondPath ?? "not set; offloading needs one")
                    .foregroundStyle(model.secondPath == nil ? .orange : .secondary)
                Spacer()
                Button(model.secondPath == nil ? "Choose…" : "Change…") {
                    if let p = BackupModel.chooseFolder(prompt: "Use for the Second Backup") { Task { await model.setSecond(p) } }
                }
            }
            if model.working { ProgressView().controlSize(.small) }
        }
        Section("Binders") {
            if model.lines.isEmpty { Text("No backups yet; they start within the hour.").foregroundStyle(.secondary) }
            ForEach(model.lines) { l in
                HStack {
                    Circle().fill(l.error != nil ? Color.red : l.at == nil ? Color.orange : Color.green).frame(width: 8, height: 8)
                    Text(l.name)
                    Spacer()
                    Text(l.error ?? l.at.map { "last backup \(String($0.prefix(16)))" } ?? "not yet")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
