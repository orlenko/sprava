import AppKit
import Combine
import Foundation
import LocalAuthentication
import Shelf
import SpravaKit
import SwiftUI

@MainActor
final class BinderIMAPModel: ObservableObject {
    @Published var mailbox = "INBOX"
    @Published var sender = ""
    @Published var subject = ""
    @Published var search = ""
    @Published var startTLS = false
    @Published var includeExisting = true
    @Published private(set) var enabled = false
    @Published private(set) var installed = true
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published var environment: URL?
    private(set) var folder: URL?
    let client: RuntimeClient
    let authenticate: () async throws -> Void
    init(client: RuntimeClient = RuntimeClient(), authenticate: @escaping () async throws -> Void = {
        guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Connect this binder to the selected IMAP account.") else { throw CancellationError() }
    }) { self.client = client; self.authenticate = authenticate }
    func show(_ folder: URL) async {
        let changed = self.folder != folder
        if changed { environment = nil; mailbox = "INBOX"; sender = ""; subject = ""; search = ""; enabled = false; self.folder = folder }
        await request("imap_status", folder: folder, loadConfiguration: changed)
    }
    func selectEnvironment() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = "Choose the private .env file used by the TECAS IMAP synchronizer. Keep it outside every binder; Sprava never sends it to Claude. It must be readable only by your account (chmod 600)."
        if panel.runModal() == .OK { environment = panel.url }
    }
    func connect() async {
        guard !busy, let folder, let environment else { return }; busy = true; defer { busy = false }
        do {
            try await authenticate()
            guard self.folder == folder else { return }
            let result = try await client.command("imap_configure", binder: folder, [
                ("environment", .str(environment.path)), ("mailbox", .str(mailbox)), ("sender", .str(sender)),
                ("subject", .str(subject)), ("search", .str(search)), ("starttls", .bool(startTLS)), ("include_existing", .bool(includeExisting))], timeout: 15)
            guard self.folder == folder else { return }; update(result); self.environment = nil
        } catch { if self.folder == folder { message = "IMAP could not connect. Refresh to check whether setup was saved, then check the private .env permissions, installed tool and mailbox." } }
    }
    func action(_ command: String) async {
        guard !busy, let folder else { return }; busy = true; defer { busy = false }
        await request(command, folder: folder)
    }
    private func request(_ command: String, folder: URL, loadConfiguration: Bool = false) async {
        do {
            let result = try await client.command(command, binder: folder, timeout: command == "imap_disable" ? 20 : 5)
            guard self.folder == folder else { return }; update(result, loadConfiguration: loadConfiguration)
        } catch { if self.folder == folder { message = "Sprava could not check IMAP. Open Health for the background connection, then Refresh before retrying a change." } }
    }
    private func update(_ result: JSONObject, loadConfiguration: Bool = false) {
        enabled = result["enabled"] == .bool(true); installed = result["installed"] == .bool(true); running = result["running"] == .bool(true)
        message = result["message"]?.stringValue
        guard enabled || loadConfiguration else { return }
        if let text = result["mailbox"]?.stringValue { mailbox = text }
        if let text = result["sender"]?.stringValue { sender = text }
        if let text = result["subject"]?.stringValue { subject = text }
        if let text = result["search"]?.stringValue { search = text }
        startTLS = result["starttls"] == .bool(true); includeExisting = result["include_existing"] != .bool(false)
    }
}

struct BinderIMAPPlugin: View {
    let row: ShelfRow
    @StateObject private var model = BinderIMAPModel()
    @State private var expanded = false
    var body: some View {
        Section {
            DisclosureGroup("IMAP intake plugin", isExpanded: $expanded) {
                Text("Import mail and attachments into this binder's intake using Sprava’s raw-message-preserving adapter and the existing TECAS .env settings. Your original server messages stay unchanged. Claude can read imported mail only when intake sharing is enabled separately.").font(.caption)
                if !model.installed {
                    Text("Install the isolated helper’s Python 3 in Terminal: brew install python").textSelection(.enabled)
                }
                if model.enabled {
                    Text(verbatim: "Mailbox: " + model.mailbox + (model.sender.isEmpty ? "" : " · From contains: " + model.sender) + (model.subject.isEmpty ? "" : " · Subject contains: " + model.subject))
                    HStack {
                        Button("Sync now") { Task { await model.action("imap_sync") } }.disabled(model.busy || model.running)
                        Button("Disable / change connection") { Task { await model.action("imap_disable") } }.disabled(model.busy)
                    }
                } else {
                    TextField("Server mailbox or label", text: $model.mailbox)
                    TextField("From contains (optional)", text: $model.sender)
                    TextField("Subject contains (optional)", text: $model.subject)
                    TextField("IMAP SEARCH (optional, e.g. UNSEEN SINCE 01-Oct-2026)", text: $model.search)
                    Text("Mailbox, From, Subject and optional IMAP SEARCH filter on the server. From/Subject are also checked against decoded headers after a private fetch. Filters never authorize marking mail read or sending anything.").font(.caption).foregroundStyle(.secondary)
                    Toggle("STARTTLS on port 143 (otherwise TLS on 993)", isOn: $model.startTLS)
                    Toggle("Include existing messages in this mailbox", isOn: $model.includeExisting)
                    Button(model.environment == nil ? "Choose private .env…" : "Private .env selected — choose another…") { model.selectEnvironment() }
                    Text("Use IMAP_HOST, IMAP_USER and IMAP_PASSWORD in that file. TLS certificates must verify; local bridges with self-signed certificates are not supported by this pilot. Disable any older watcher for this mailbox first to avoid duplicate imports.").font(.caption).foregroundStyle(.secondary)
                    Button("Enable IMAP plugin for this binder") { Task { await model.connect() } }
                        .disabled(model.busy || !model.installed || model.environment == nil || model.mailbox.isEmpty || !row.teka.isAdopted)
                }
                HStack {
                    Button("Refresh") { Task { await model.action("imap_status") } }.disabled(model.busy)
                    if model.running || model.busy { ProgressView().controlSize(.small) }
                }
                if let message = model.message { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
            }
        }.task(id: row.folder) {
            await model.show(row.folder)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3)); if Task.isCancelled { break }
                if !model.busy { await model.show(row.folder) }
            }
        }
    }
}
