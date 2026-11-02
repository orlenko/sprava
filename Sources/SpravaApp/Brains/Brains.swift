import Combine
import Shelf
import SpravaKit
import SwiftUI

/// Assistant setup stays in ClaudeAccountView. This model only retires old external connections (D29).
@MainActor
final class BrainsModel: ObservableObject, RuntimePage {
    struct Client: Identifiable { let id: String; let name: String; let binders: [String: String] }
    static let claudeCodeID = "claude-code-1"
    @Published private(set) var clients: [Client] = []
    @Published private(set) var legacyTerminal = false
    @Published var message: String? { didSet { readFoundNoRuntime = false } }
    var readFoundNoRuntime = false
    @Published private(set) var busy = false
    let client: RuntimeClient

    init(client: RuntimeClient = RuntimeClient()) {
        self.client = client
        client.clearsNotRunning(self)
    }

    /// Opening Assistant retires the capability minted by the old installer. Never runs a personal Claude
    /// executable or edits its settings: the installer did not record which profile it changed (D29).
    func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await readClients()
            if let terminal = clients.first(where: { $0.id == Self.claudeCodeID }) {
                await revoke(terminal)
            }
        } catch { readFailed(Self.plain(error, "Older connections could not be checked. Try again in a moment."), error) }
    }

    private func readClients() async throws {
        let r = try await client.global("list_clients", timeout: 5)
        legacyTerminal = r["legacy_terminal"] == .bool(true)
        clients = (r["clients"]?.arrayValue ?? []).compactMap { c in
            guard let id = c["id"]?.stringValue else { return nil }
            var binders: [String: String] = [:]
            for e in c["binders"]?.objectValue?.entries ?? [] { binders[e.key] = e.value.stringValue }
            return Client(id: id, name: c["name"]?.stringValue ?? id, binders: binders)
        }
    }

    func disconnect(_ connection: Client) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await revoke(connection)
    }

    private func revoke(_ connection: Client) async {
        do {
            _ = try await client.global("revoke_client", [("client_id", .str(connection.id))])
            message = nil
            if connection.id == Self.claudeCodeID { legacyTerminal = true }
        } catch let failure as RuntimeClient.Failure where failure.kind == .refused && failure.message.contains("revoked") {
            message = "Access was revoked, but some older suggestions could not be withdrawn. Review them in their binders."
        } catch {
            message = Self.plain(error, "The older connection could not be disconnected. Try again in a moment.")
        }
        do { try await readClients() }
        catch { message = Self.plain(error, "The connections could not be refreshed. Check again before retrying.") }
    }

    static func plain(_ error: Error, _ fallback: String) -> String {
        guard let failure = error as? RuntimeClient.Failure else { return fallback }
        switch failure.kind {
        case .notRunning: return failure.message
        case .timedOut: return "Sprava did not answer in time. Check this page again before retrying."
        case .refused: return fallback
        }
    }
}

struct BrainsView: View {
    @StateObject private var claudeAccount = ClaudeAccountModel()
    @ObservedObject var model: BrainsModel
    let rows: [ShelfRow]

    func names(_ connection: BrainsModel.Client) -> String {
        connection.binders.keys.map { path in
            rows.first { $0.folder.standardizedFileURL.path == path }?.name ?? URL(fileURLWithPath: path).lastPathComponent
        }.sorted().joined(separator: ", ")
    }

    var body: some View {
        List {
            ClaudeAccountView(model: claudeAccount)
            Text("Your own Claude Code sessions can open a binder folder directly. Sprava no longer installs a connection in those sessions.")
                .font(.caption).foregroundStyle(.secondary)
            if model.legacyTerminal {
                Section("Older Terminal setup") {
                    Text("The old Sprava connection has been retired. A leftover entry may remain in your Claude Code profile settings.")
                    Text("Remove an entry only if its command points to Sprava.app/Contents/MacOS/sprava-mcp and its arguments are --client claude-code-1. Sprava did not record which profile it changed, so it leaves those settings untouched.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.clients.isEmpty {
                Section("Older external connections") {
                    ForEach(model.clients) { connection in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(connection.name).font(.headline)
                                Text(names(connection)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Disconnect") { Task { await model.disconnect(connection) } }.disabled(model.busy)
                        }
                    }
                }
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .task { await model.load() }
    }
}
