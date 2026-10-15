import AppKit
import Combine
import LocalAuthentication
import Shelf
import SpravaKit
import SwiftUI

/// "Connect a brain" (architecture 7.5; mvp.md feature 10): register Claude Code for chosen binders, show the
/// exact registration once, and run it for the person with no shell. Revoke is one click.
@MainActor
final class BrainsModel: ObservableObject {
    struct Client: Identifiable { let id: String; let name: String; let binders: [String: String]; let documents: Bool }

    @Published var clients: [Client] = []
    @Published var chosen: Set<URL> = []
    @Published var clientID = "claude-code-1"
    /// One immutable registration binds the command, fallback config and displayed scope to the same token.
    struct Registration: Equatable {
        let arguments: [String]
        let clientID: String
        let binderPaths: [String]
        let configuration: String
    }

    @Published var registration: Registration?
    @Published var message: String?
    @Published var registering = false
    let client: RuntimeClient
    let authenticate: () async throws -> Void

    init(client: RuntimeClient = RuntimeClient(),
         authenticate: @escaping () async throws -> Void = { try await BrainsModel.authenticatePerson() }) {
        self.client = client
        self.authenticate = authenticate
        client.clearsNotRunning(self, \.message)
    }

    /// Client registration and widening document access require the person, beyond UI automation (architecture 2.1).
    private static func authenticatePerson() async throws {
        let context = LAContext()
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: "Allow this brain to read the binders and documents you chose.") else {
            throw AuthenticationFailure.refused
        }
    }

    private enum AuthenticationFailure: Error { case refused }

    static var shimPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sprava-mcp").path }

    func load() async {
        do {
            let r = try await client.global("list_clients", timeout: 5)
            clients = (r["clients"]?.arrayValue ?? []).compactMap { c in
                guard let id = c["id"]?.stringValue else { return nil }
                var b: [String: String] = [:]
                for e in c["binders"]?.objectValue?.entries ?? [] { b[e.key] = e.value.stringValue }
                return Client(id: id, name: c["name"]?.stringValue ?? id, binders: b, documents: c["documents"] == .bool(true))
            }
        } catch { message = "\(error)" }
    }

    var canEditRegistrationChoices: Bool { registration == nil && !registering && !running }

    func register() async {
        guard canEditRegistrationChoices else { return }
        registering = true
        defer { registering = false }
        let id = clientID
        let folders = chosen.map { $0.standardizedFileURL.path }.sorted()
        let scope = folders.map { ($0, JSONValue.str("propose")) }
        do {
            try await authenticate()
            let r = try await client.global("register_client", [("client_id", .string(id)), ("name", .str("Claude Code")),
                                                                ("binders", .obj(scope))])
            guard let token = r["token"]?.stringValue else {
                message = "The registration reply did not include a token. Reload the connected clients before trying again."
                return
            }
            // The exact command, every argument shown (SEP-1024); --scope user so no .mcp.json lands in a folder.
            let args = ["claude", "mcp", "add", "--scope", "user", "--env", "SPRAVA_CLIENT_TOKEN=\(token)",
                        "--transport", "stdio", "sprava", "--", Self.shimPath, "--client", id]
            let configuration = JSONWriter.pretty(.obj([("mcpServers", .obj([("sprava", .obj([
                ("type", .str("stdio")), ("command", .str(Self.shimPath)),
                ("args", .array([.str("--client"), .str(id)])),
                ("env", .obj([("SPRAVA_CLIENT_TOKEN", .str(token))]))
            ]))]))]))
            registration = Registration(arguments: args, clientID: id, binderPaths: folders, configuration: configuration)
            message = nil
            await load()
        } catch { message = "\(error)" }
    }

    /// The exact command shown for inspection: an argument with a space or another character the shell
    /// reads (an app folder such as "Personal Apps") is single-quoted, so it stays one argument.
    static func shellLine(_ args: [String]) -> String {
        let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%+=:,./_-")
        return args.map { arg in
            if !arg.isEmpty, arg.unicodeScalars.allSatisfy(plain.contains) { return arg }
            return "'" + arg.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }.joined(separator: " ")
    }

    func copyRegistration() {
        guard let registration else { return }
        message = ProtectedClipboard.copy(registration.configuration)
            ? "Configuration copied for this Mac only. It clears from the clipboard after 60 seconds."
            : "The configuration could not be copied. Try again."
    }

    /// Where Claude Code is installed, if it is; tests put their own program here.
    var claude: () -> URL? = {
        ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude"]
            .map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
    var timeout: TimeInterval = 60
    @Published var running = false

    /// Runs `claude mcp add` directly, with no shell, so the token never lands in a shell history file. It runs off
    /// the main actor and is stopped after `timeout`, so a stalled Claude Code never leaves the app unresponsive.
    func runRegistration() async {
        guard let pending = registration, !running, !registering else { return }
        guard let path = claude() else {
            message = "Claude Code was not found. Add the configuration below to your user MCP settings in ~/.claude.json, preserving the other entries."
            return
        }
        running = true
        defer { running = false }
        do {
            let r = try await ChildRun(executable: path, arguments: Array(pending.arguments.dropFirst()), timeout: timeout).run()
            guard registration == pending else { return }
            switch r.ending {
            case .exited(0):
                message = "Claude Code is connected. Restart its session to see Sprava's tools."
                registration = nil
            case .exited:
                let said = String(decoding: r.stderr.isEmpty ? r.stdout : r.stderr, as: UTF8.self)
                message = "claude mcp add failed: \(said.suffix(300))"
            case .timedOut:
                message = "Claude Code did not finish in \(Int(timeout)) seconds and was stopped. Try Run It for Me again, or add the configuration below to your user MCP settings in ~/.claude.json, preserving the other entries."
            }
        } catch { message = "\(error)" }
    }

    /// Whether this brain may read the text of documents waiting for a careful reading.
    func setDocuments(_ c: Client, _ allowed: Bool) async {
        do {
            if allowed { try await authenticate() }
            _ = try await client.global("client_documents", [("client_id", .string(c.id)), ("documents", .bool(allowed))])
        } catch { message = "\(error)" }
        await load()
    }

    func cancelRegistration() async {
        guard let pending = registration, !running, !registering else { return }
        await revokeClient(pending.clientID)
    }

    func revoke(_ c: Client) async { await revokeClient(c.id) }

    private func revokeClient(_ id: String) async {
        do {
            _ = try await client.global("revoke_client", [("client_id", .string(id))])
            if registration?.clientID == id { registration = nil }
            message = nil
        } catch { message = "\(error)" }
        await load()
    }
}

struct BrainsView: View {
    @ObservedObject var model: BrainsModel
    let rows: [ShelfRow]

    var body: some View {
        List {
            Section("What connecting means") {
                Text("""
                A connected brain (an AI tool such as Claude Code) can read the binders you choose, within each binder's \
                privacy setting, and propose changes. It cannot apply anything: every change waits for you here. \
                What it reads goes to the model provider that tool uses. Claude Code can also read binder folders with its own \
                file tools. In its permission settings, deny Read, Edit and Write on each entire binder folder, on the capture \
                root and on ~/Library/Application Support/Sprava, or use its sandbox controls. Sprava cannot verify those settings.
                """).foregroundStyle(.secondary)
            }
            Section("Connected") {
                if model.clients.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(model.clients) { c in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(c.name) (\(c.id))").font(.headline)
                            Text("\(c.binders.count) binder(s)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("May read documents", isOn: Binding(get: { c.documents }, set: { allowed in Task { await model.setDocuments(c, allowed) } }))
                            .help("Lets this brain read the text of intake documents the clerk recommends a careful reading of, in its binders.")
                        Button("Revoke") { Task { await model.revoke(c) } }
                    }
                }
            }
            Section("Connect Claude Code") {
                ForEach(rows.filter { $0.teka.isAdopted }, id: \.folder) { row in
                    Toggle(row.name, isOn: Binding(get: { model.chosen.contains(row.folder) },
                                                   set: { on in if on { model.chosen.insert(row.folder) } else { model.chosen.remove(row.folder) } }))
                }
                .disabled(!model.canEditRegistrationChoices)
                TextField("Client id", text: $model.clientID).disabled(!model.canEditRegistrationChoices)
                Button("Create Registration") { Task { await model.register() } }
                    .disabled(model.chosen.isEmpty || !model.canEditRegistrationChoices)
                if let pending = model.registration {
                    Text("Registration for \(pending.clientID)").font(.headline)
                    ForEach(pending.binderPaths, id: \.self) { Text($0).font(.caption) }
                    Text("Shown once. This is the exact command Sprava runs:").font(.caption)
                    Text(BrainsModel.shellLine(pending.arguments)).font(.caption.monospaced())
                    Button("Run It for Me") { Task { await model.runRegistration() } }.disabled(model.running || model.registering)
                    Text("Manual setup: merge this sprava entry into mcpServers in ~/.claude.json, preserving other entries. This configuration is for a file, not Terminal.").font(.caption)
                    Text(pending.configuration).font(.caption.monospaced())
                    Button("Copy Configuration") { model.copyRegistration() }
                    Button("Cancel Registration") { Task { await model.cancelRegistration() } }.disabled(model.running || model.registering)
                }
                if let m = model.message { Text(m).foregroundStyle(.orange) }
            }
        }
        .task { await model.load() }
    }
}
