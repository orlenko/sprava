import AppKit
import Combine
import SpravaCore
import SwiftUI

/// Settings › Backup and the offloaded binders (docs/backup.md §7). Everything runs in the runtime; slow work is
/// queued there and this page watches it.
@MainActor
final class BackupModel: ObservableObject {
    struct Offloaded: Identifiable {
        let id: String
        let name: String
        let bytes: Int
        let at: String
        let documents: [(title: String, path: String)]
    }
    struct Line: Identifiable { let id = UUID(); let name: String; let at: String?; let error: String? }
    struct Request: Identifiable { let id: String; let kind: String; let state: String; let message: String? }

    @Published var configured = false
    @Published var primary = Backup.defaultPrimary.path
    @Published var secondPath: String?
    @Published var upload: String?
    @Published var lastCheck: String?
    @Published var lastDrill: String?
    @Published var lines: [Line] = []
    @Published var offloaded: [Offloaded] = []
    @Published var requests: [Request] = []
    @Published var newKey: String?
    @Published var typedKey = ""
    @Published var iCloudKeychain = false
    @Published var message: String?
    let client = RuntimeClient()

    func load() async {
        do {
            let r = try await client.global("backup_status", timeout: 10)
            configured = r["configured"] == .bool(true)
            if let p = r["primary"]?.stringValue { primary = p }
            secondPath = r["second_path"]?.stringValue
            upload = r["upload"]?.stringValue
            lastCheck = r["last_check"]?.stringValue
            lastDrill = r["last_drill"]?.stringValue
            lines = (r["binders"]?.arrayValue ?? []).map { Line(name: $0["name"]?.stringValue ?? "?", at: $0["at"]?.stringValue, error: $0["error"]?.stringValue) }
            offloaded = (r["offloaded"]?.arrayValue ?? []).compactMap { o in
                guard let id = o["id"]?.stringValue else { return nil }
                return Offloaded(id: id, name: o["name"]?.stringValue ?? "?", bytes: Int(o["bytes"]?.numberValue?.safeInteger ?? 0),
                                 at: o["at"]?.stringValue ?? "",
                                 documents: (o["documents"]?.arrayValue ?? []).map { ($0["title"]?.stringValue ?? "", $0["path"]?.stringValue ?? "") })
            }
            requests = (r["requests"]?.arrayValue ?? []).compactMap { q in
                guard let id = q["id"]?.stringValue else { return nil }
                return Request(id: id, kind: q["kind"]?.stringValue ?? "", state: q["state"]?.stringValue ?? "", message: q["message"]?.stringValue)
            }
        } catch { message = "\(error)" }
    }

    func chooseFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func createKey() {
        Task {
            do { newKey = try await client.global("backup_new_key")["key"]?.stringValue } catch { message = "\(error)" }
        }
    }

    func setUp() {
        Task {
            do {
                _ = try await client.global("backup_setup", [("key", .string(typedKey)), ("primary", .string(primary)),
                                                              ("icloud_keychain", .bool(iCloudKeychain))], timeout: 120)
                newKey = nil
                typedKey = ""
                message = "Backup is set up. The first backups start within the hour."
                await load()
            } catch { message = "\(error)" }
        }
    }

    func setSecond() {
        guard let path = chooseFolder(prompt: "Use for the Second Backup") else { return }
        Task {
            do { _ = try await client.global("backup_second", [("folder", .string(path))], timeout: 120); await load() } catch { message = "\(error)" }
        }
    }

    func request(_ kind: String, binder: URL? = nil, backupID: String? = nil, confirm: Bool = false) {
        Task {
            do {
                var fields: [(String, JSONValue)] = [("kind", .string(kind)), ("confirm_open_items", .bool(confirm))]
                if let backupID { fields.append(("backup_id", .string(backupID))) }
                if let binder {
                    _ = try await client.command("backup_request", binder: binder, fields)
                } else {
                    _ = try await client.global("backup_request", fields)
                }
                message = "Started. It continues in the background; this page shows its progress."
                await load()
            } catch { message = "\(error)" }
        }
    }

    func peek(_ o: Offloaded, path: String) {
        Task {
            do {
                let r = try await client.global("peek", [("backup_id", .string(o.id)), ("path", .string(path))], timeout: 600)
                if let file = r["file"]?.stringValue { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }
            } catch { message = "\(error)" }
        }
    }
}

struct BackupView: View {
    @ObservedObject var model: BackupModel

    var body: some View {
        List {
            if let message = model.message { Text(message).foregroundStyle(.orange) }
            if !model.configured { setup } else { status }
            if !model.requests.isEmpty {
                Section("In progress and recent") {
                    ForEach(model.requests) { r in
                        HStack(alignment: .top) {
                            Text(r.kind.replacingOccurrences(of: "_", with: " ")).frame(width: 90, alignment: .leading)
                            Text(r.state.replacingOccurrences(of: "_", with: " ")).foregroundStyle(r.state == "failed" ? .red : .secondary)
                            if let m = r.message { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                        }
                    }
                }
            }
            Section("Offloaded binders") {
                if model.offloaded.isEmpty { Text("None. Offload a finished binder from its page.").foregroundStyle(.secondary) }
                ForEach(model.offloaded) { o in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(o.name).font(.headline)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(o.bytes), countStyle: .file)).foregroundStyle(.secondary)
                            Text("offloaded \(String(o.at.prefix(10)))").foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") { model.request("restore", backupID: o.id) }
                        }
                        if !o.documents.isEmpty {
                            Menu("Open a document") {
                                ForEach(o.documents, id: \.path) { d in Button(d.title) { model.peek(o, path: d.path) } }
                            }
                            .frame(maxWidth: 220)
                        }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await model.load()
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
                Button("Choose…") { if let p = model.chooseFolder(prompt: "Use for Backup") { model.primary = p } }
            }
            Toggle("Also keep the key in iCloud Keychain (recovery on a new Mac without typing it; less private)", isOn: $model.iCloudKeychain)
            if let key = model.newKey {
                Text("Your backup key. Save it where you keep such things, such as a password manager. Without it the backup cannot be opened.")
                HStack {
                    Text(key).font(.title3.monospaced()).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key, forType: .string)
                    }
                }
                TextField("Type the key back to confirm you saved it", text: $model.typedKey).textFieldStyle(.roundedBorder)
                Button("Set Up Backup") { model.setUp() }.disabled(model.typedKey.isEmpty)
            } else {
                HStack {
                    Button("Create a Key") { model.createKey() }
                    Text("or, with a key from an earlier setup:").foregroundStyle(.secondary)
                    TextField("paste it here", text: $model.typedKey).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Button("Use It") { model.setUp() }.disabled(model.typedKey.isEmpty)
                }
            }
        }
    }

    @ViewBuilder var status: some View {
        Section("Backup") {
            LabeledContent("Mirror", value: model.primary)
            LabeledContent("iCloud", value: model.upload ?? "checking…")
            LabeledContent("Last check", value: model.lastCheck.map { String($0.prefix(16)) } ?? "not yet")
            LabeledContent("Last restore drill", value: model.lastDrill.map { String($0.prefix(16)) } ?? "never")
            HStack {
                Text("Second backup").frame(width: 120, alignment: .leading)
                Text(model.secondPath ?? "not set; offloading needs one").foregroundStyle(model.secondPath == nil ? .orange : .secondary)
                Spacer()
                Button(model.secondPath == nil ? "Choose…" : "Change…") { model.setSecond() }
            }
        }
        Section("Binders") {
            if model.lines.isEmpty { Text("No backups yet; they start within the hour.").foregroundStyle(.secondary) }
            ForEach(model.lines) { l in
                HStack {
                    Circle().fill(l.error != nil ? Color.red : l.at == nil ? Color.orange : Color.green).frame(width: 8, height: 8)
                    Text(l.name)
                    Spacer()
                    Text(l.error ?? l.at.map { "last backup \(String($0.prefix(16)))" } ?? "not yet").foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// The "Offload…" control on a binder's page (docs/backup.md §6.1).
struct OffloadSection: View {
    @ObservedObject var backup: BackupModel
    let folder: URL
    let openItems: [String]

    var body: some View {
        Section(header: Text("Done with this binder?").font(.headline)) {
            HStack {
                Text("Offloading moves the whole binder into your backups and off this Mac. You can restore it with one click.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Offload…") { confirm() }
            }
        }
    }

    func confirm() {
        let alert = NSAlert()
        alert.messageText = "Offload this binder?"
        var text = "Sprava takes a snapshot, checks it by restoring it, waits for iCloud, copies it to your second backup, then moves the folder to the Trash."
        if !openItems.isEmpty {
            text += "\n\n\(openItems.count) open item(s) will stop showing on the Shelf, in the daily summary and on the hub:\n• "
                + openItems.prefix(8).joined(separator: "\n• ") + (openItems.count > 8 ? "\n…" : "")
        }
        alert.informativeText = text
        alert.addButton(withTitle: openItems.isEmpty ? "Offload" : "Offload Anyway")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        backup.request("offload", binder: folder, confirm: true)
    }
}
