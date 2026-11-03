import AppKit
import Combine
import Shelf
import SpravaKit
import SwiftUI

/// The Backup page (docs/backup.md §4, §5, §7): setting up the mirror and its key, the second backup, and what the
/// runtime reports. Everything goes through the runtime's backup commands; slow work runs there and this page reads
/// its status again. Restore, peek and offloaded binders join with their commands.
@MainActor
final class BackupModel: ObservableObject, RuntimePage {
    struct Line: Identifiable, Equatable { let id: Int; let name: String; let at: String?; let error: String? }
    struct Request: Identifiable, Equatable {
        let id: String; let kind: String; let state: String; let message: String?; var binder: String? = nil
    }
    /// The states of a request the backup job has yet to finish (`BackupRequests.pending`).
    static let pendingStates: Set<String> = ["queued", "running", "waiting_for_icloud"]

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
    /// A configured backup whose key the runtime cannot read (after an update of an ad-hoc build, or a locked Keychain).
    @Published var keyUnavailable = false
    /// The last save of the key could not reach iCloud Keychain, so a copy an earlier build kept there may remain.
    @Published var iCloudKeychainUnchecked = false
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
    /// The binder the restore drill restores (docs/backup.md §8), and the drill request this page follows.
    @Published var drillBinder: URL?
    @Published var drillRequest: String?
    @Published private(set) var drillSending = false
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
            let wasUnavailable = keyUnavailable
            keyUnavailable = r["key_unavailable"] == .bool(true)
            iCloudKeychainUnchecked = r["icloud_keychain_unchecked"] == .bool(true)
            // A key re-entered for a configured backup keeps the person's iCloud Keychain choice.
            // The saved choice, until the person changes it on the re-entry screen (the page reloads every 5 seconds).
            if configured == true || (keyUnavailable && !wasUnavailable) { iCloudKeychain = r["icloud_keychain"] == .bool(true) }
            lines = (r["binders"]?.arrayValue ?? []).enumerated().map { i, b in
                Line(id: i, name: b["name"]?.stringValue ?? "?", at: b["at"]?.stringValue, error: b["error"]?.stringValue)
            }
            requests = (r["requests"]?.arrayValue ?? []).compactMap { q in
                guard let id = q["id"]?.stringValue else { return nil }
                return Request(id: id, kind: q["kind"]?.stringValue ?? "", state: q["state"]?.stringValue ?? "",
                               message: q["message"]?.stringValue, binder: q["binder"]?.stringValue)
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

    /// The backup key typed again for a configured backup whose key the runtime cannot read. It goes through setup at
    /// the same mirror, which opens the repository with it before saving anything: a wrong key changes nothing. This
    /// explicit save is the one time macOS may ask to let Sprava use the key.
    func reenterKey() async {
        guard !working, keyUnavailable, !typedKey.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            _ = try await client.global("backup_setup", [("key", .string(typedKey)), ("primary", .string(primary)),
                                                          ("icloud_keychain", .bool(iCloudKeychain))], timeout: 300)
            typedKey = ""
            message = "The backup key is in use again."
        } catch {
            message = "The backup key was not used: \(error)"
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

    /// A drill the backup job has not finished yet, this page's or one queued before.
    var pendingDrill: Request? { requests.first { $0.kind == "drill" && Self.pendingStates.contains($0.state) } }

    /// One drill at a time, only once backup is set up and the runtime has answered.
    func canRunDrill(_ binder: URL?) -> Bool {
        configured == true && binder != nil && !working && !drillSending && pendingDrill == nil
    }

    /// Queues a restore drill of `binder` against the mirror. The runtime's backup job runs it; this only waits for the
    /// queue's answer, never for restic. Being queued is not passing: the page says so only once the request is done.
    func runDrill(_ binder: URL) async {
        guard canRunDrill(binder) else { return }
        drillSending = true
        defer { drillSending = false }
        do {
            let r = try await client.global("backup_request", [("kind", .str("drill")), ("binder", .string(binder.path)),
                                                               ("repository", .str("primary"))])
            drillRequest = r["request"]?.stringValue
            message = nil
        } catch {
            message = "The restore drill was not started: \(error)"
        }
        await load()
    }

    /// The drill this page queued, or one still pending, as the backup job last reported it.
    var drillStatus: String? {
        guard let id = drillRequest ?? pendingDrill?.id else { return nil }
        guard let r = requests.first(where: { $0.id == id }) else { return "Restore drill requested; waiting for the background part to list it." }
        switch r.state {
        case "queued": return "Restore drill queued. It runs in the background; this page shows its result."
        case "running": return "Restore drill running\u{2026}"
        case "done": return "Restore drill passed."
        case "failed": return "Restore drill failed: \(r.message ?? "no reason was given")"
        default: return "Restore drill: \(r.state.replacingOccurrences(of: "_", with: " "))"
        }
    }

    /// A folder as a person knows it: iCloud Drive by that name, and the home folder as `~`.
    static func shown(path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let root = home.hasSuffix("/") ? String(home.dropLast()) : home
        let iCloud = root + "/Library/Mobile Documents/com~apple~CloudDocs"
        if path == iCloud { return "iCloud Drive" }
        if path.hasPrefix(iCloud + "/") { return "iCloud Drive/" + path.dropFirst(iCloud.count + 1) }
        if path == root { return "~" }
        return path.hasPrefix(root + "/") ? "~/" + path.dropFirst(root.count + 1) : path
    }

    /// A recorded time in the person's own format; one that cannot be read is shown as it was recorded.
    static func shown(time: String?) -> String? {
        guard let time else { return nil }
        guard let date = ISOTime.date(time) else { return String(time.prefix(16)) }
        return date.formatted(date: .abbreviated, time: .shortened)
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
    /// The Shelf's binders; a drill can restore any that Sprava keeps here.
    var rows: [ShelfRow] = []

    var drillable: [ShelfRow] { rows.filter { !$0.archived && $0.teka.isAdopted && !$0.teka.writesBlocked } }

    var body: some View {
        // A plain column: rows size to what they hold, and lines stay a readable length in a wide window.
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
            if let message = model.message { Text(message).foregroundStyle(.orange) }
            if let error = model.stateError { Text("Backup records cannot be read: \(error)").foregroundStyle(.red) }
            switch model.configured {
            case nil: Text("Asking Sprava's background part…").foregroundStyle(.secondary)
            // Set up, but the key cannot be read: type it again, never a new setup that would make a new key.
            case false? where model.keyUnavailable: keyAgain
            case false?: setup
            case true?: status
            }
            if !model.requests.isEmpty {
                BackupGroup("In progress and recent") {
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
            .frame(maxWidth: 620, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        BackupGroup("Set up backup") {
            Text("Sprava keeps an encrypted copy of every binder in a folder of your iCloud Drive. Only your key opens it.")
                .fixedSize(horizontal: false, vertical: true)
            BackupRow("Backup folder") {
                HStack {
                    Text(BackupModel.shown(path: model.primary)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(model.primary)
                    Button("Choose…") { if let p = BackupModel.chooseFolder(prompt: "Use for Backup") { model.primary = p } }
                }
            }
        }
        BackupGroup("Your key") {
            if let key = model.newKey {
                Text("Save this key where you keep such things, such as a password manager. Without it the backup cannot be opened.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(key).font(.title3.monospaced()).textSelection(.enabled)
                    Button("Copy") { _ = ProtectedClipboard.copy(key, lifetime: .seconds(120)) }
                }
                keychainChoice
                TextField("Type the key back to confirm you saved it", text: $model.typedKey).textFieldStyle(.roundedBorder)
                Button("Set Up Backup") { Task { await model.setUp() } }.disabled(model.typedKey.isEmpty)
            } else {
                if model.pendingKey {
                    Text("A key was made earlier and not yet confirmed. Type that key below, or create a new one.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button("Create a Key") { Task { await model.createKey() } }
                keychainChoice
                Divider()
                Text(model.pendingKey ? "The key shown earlier" : "Have a key from an earlier setup?").foregroundStyle(.secondary)
                HStack {
                    TextField("Paste it here", text: $model.typedKey).textFieldStyle(.roundedBorder)
                    Button("Use It") { Task { await model.setUp() } }.disabled(model.typedKey.isEmpty)
                }
            }
            if model.working { ProgressView().controlSize(.small) }
        }
    }

    var keychainChoice: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Also keep the key in iCloud Keychain", isOn: $model.iCloudKeychain)
            Text("Lets you recover on a new Mac without typing it. Less private.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Restores one binder from the mirror into a temporary folder and compares it (docs/backup.md §8).
    @ViewBuilder var drill: some View {
        let chosen = model.drillBinder ?? drillable.first?.folder
        BackupRow("Restore drill") {
            if drillable.isEmpty {
                Text("No binder here to restore yet.").foregroundStyle(.secondary)
            } else {
                Picker("Binder", selection: Binding(get: { chosen }, set: { model.drillBinder = $0 })) {
                    ForEach(drillable, id: \.folder) { Text($0.name).tag(Optional($0.folder)) }
                }
                .labelsHidden().fixedSize()
                Button("Run") { if let chosen { Task { await model.runDrill(chosen) } } }
                    .disabled(!model.canRunDrill(chosen))
            }
        }
        if let status = model.drillStatus {
            Text(status).font(.caption).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(status.hasPrefix("Restore drill failed") ? .red : .secondary)
        }
    }

    @ViewBuilder var keyAgain: some View {
        BackupGroup("Backup key") {
            Text("Sprava's background part cannot read the backup key, so backups have stopped. This happens after an update of this development build, or while the Keychain is locked. Type the backup key to use it again; if macOS asks to let Sprava use it, choose Always Allow so backups run unattended.")
                .foregroundStyle(.orange)
            Toggle("Also keep the key in iCloud Keychain", isOn: $model.iCloudKeychain)
            HStack {
                TextField("backup key", text: $model.typedKey).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button("Use This Key") { Task { await model.reenterKey() } }.disabled(model.typedKey.isEmpty)
            }
        }
    }

    @ViewBuilder var status: some View {
        if model.iCloudKeychainUnchecked {
            Text("iCloud Keychain is unavailable in this development build, so Sprava could not check it for a backup key an earlier Sprava build kept there. Only that build can remove such a copy.")
                .font(.caption).foregroundStyle(.orange)
        }
        BackupGroup("Backup") {
            BackupRow("Backup folder") {
                Text(BackupModel.shown(path: model.primary)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(model.primary)
            }
            BackupRow("iCloud") { Text(model.upload ?? "not checked yet").foregroundStyle(.secondary) }
            BackupRow("Last check") { Text(BackupModel.shown(time: model.lastCheck) ?? "not yet").foregroundStyle(.secondary) }
            BackupRow("Last restore drill") { Text(BackupModel.shown(time: model.lastDrill) ?? "never").foregroundStyle(.secondary) }
            BackupRow("Second backup") {
                HStack {
                    Text(model.secondPath.map { BackupModel.shown(path: $0) } ?? "not set; offloading needs one")
                        .foregroundStyle(model.secondPath == nil ? .orange : .secondary).lineLimit(1).truncationMode(.middle)
                        .help(model.secondPath ?? "")
                    Button(model.secondPath == nil ? "Choose…" : "Change…") {
                        if let p = BackupModel.chooseFolder(prompt: "Use for the Second Backup") { Task { await model.setSecond(p) } }
                    }
                }
            }
            drill
            if model.working { ProgressView().controlSize(.small) }
        }
        BackupGroup("Binders") {
            if model.lines.isEmpty { Text("No backups yet; they start within the hour.").foregroundStyle(.secondary) }
            ForEach(model.lines) { l in
                HStack(alignment: .firstTextBaseline) {
                    Circle().fill(l.error != nil ? Color.red : l.at == nil ? Color.orange : Color.green).frame(width: 8, height: 8)
                    Text(l.name)
                    Spacer()
                    Text(l.error ?? BackupModel.shown(time: l.at).map { "last backup \($0)" } ?? "not yet")
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A label and what it describes, so a page's values line up in one column.
private struct BackupRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 130, alignment: .leading)
            HStack(alignment: .firstTextBaseline) { content }
        }
    }
}

/// One titled part of the Backup page.
private struct BackupGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
