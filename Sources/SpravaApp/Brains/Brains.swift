import AppKit
import Combine
import LocalAuthentication
import Shelf
import SpravaKit
import SwiftUI

/// "Connect a brain" (architecture 7.5; mvp.md feature 10): one button connects Claude Code to the binders the
/// person ticks. Sprava picks the client id itself, and connecting again renews the connection with the binders now
/// ticked, so there is nothing to name and nothing that can already exist. Disconnect is one click.
@MainActor
final class BrainsModel: ObservableObject {
    struct Client: Identifiable { let id: String; let name: String; let binders: [String: String]; let documents: Bool }

    /// The one id Sprava gives Claude Code. Connecting again renews this client instead of adding another.
    static let claudeCodeID = "claude-code-1"
    /// The name of Sprava's entry in Claude Code's settings.
    static let serverName = "sprava"

    @Published var clients: [Client] = []
    /// The ticked binders, as standardized folder paths (the form the runtime keeps a scope in).
    @Published var chosen: Set<String> = []
    /// Set once the person ticks or unticks a binder, so a reload never overwrites their choice.
    private var choseByHand = false

    /// A connection Sprava could not write into Claude Code's settings itself: the setup the person adds by hand.
    /// One immutable value binds the command, the configuration and the displayed scope to the same token.
    struct Registration: Equatable {
        let arguments: [String]
        let clientID: String
        let binderPaths: [String]
        let configuration: String
    }

    @Published var registration: Registration?
    @Published var message: String?
    @Published var busy = false
    let client: RuntimeClient
    let authenticate: () async throws -> Void

    init(client: RuntimeClient = RuntimeClient(),
         authenticate: @escaping () async throws -> Void = { try await BrainsModel.authenticatePerson() }) {
        self.client = client
        self.authenticate = authenticate
    }

    /// Connecting and widening document access require the person, beyond UI automation (architecture 2.1).
    private static func authenticatePerson() async throws {
        let context = LAContext()
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: "Allow Claude Code to see the binders you chose.") else {
            throw AuthenticationFailure.refused
        }
    }

    private enum AuthenticationFailure: Error { case refused }

    static var shimPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sprava-mcp").path }

    /// Claude Code's connection, when there is one.
    var claudeCode: Client? { clients.first { $0.id == Self.claudeCodeID } }
    /// Connections made some other way, such as an earlier build that let the person name them.
    var others: [Client] { clients.filter { $0.id != Self.claudeCodeID } }

    var canConnect: Bool { !busy && !chosen.isEmpty }

    func choose(_ folder: URL, _ on: Bool) {
        guard !busy else { return }
        choseByHand = true
        let path = folder.standardizedFileURL.path
        if on { chosen.insert(path) } else { chosen.remove(path) }
    }

    func load() async {
        do {
            let r = try await client.global("list_clients", timeout: 5)
            clients = (r["clients"]?.arrayValue ?? []).compactMap { c in
                guard let id = c["id"]?.stringValue else { return nil }
                var b: [String: String] = [:]
                for e in c["binders"]?.objectValue?.entries ?? [] { b[e.key] = e.value.stringValue }
                return Client(id: id, name: c["name"]?.stringValue ?? id, binders: b, documents: c["documents"] == .bool(true))
            }
            // The ticks start as the binders Claude Code already sees, until the person changes them.
            if !choseByHand { chosen = Set(claudeCode?.binders.keys.map { $0 } ?? []) }
        } catch { message = Self.plain(error, "The connections could not be loaded. Try again in a moment.") }
    }

    /// The arguments for `claude mcp add`; `--scope user` so no `.mcp.json` lands in a folder (architecture 7.5).
    static func addArguments(token: String) -> [String] {
        ["claude", "mcp", "add", "--scope", "user", "--env", "SPRAVA_CLIENT_TOKEN=\(token)",
         "--transport", "stdio", serverName, "--", shimPath, "--client", claudeCodeID]
    }

    /// Removes an earlier Sprava entry first: `claude mcp add` refuses a name that is already there.
    static let removeArguments = ["claude", "mcp", "remove", "--scope", "user", serverName]

    /// Connects Claude Code to the ticked binders, or renews its connection with them: a new key, the new scope, and
    /// Claude Code's settings rewritten to match. Registering the same id again is never an error.
    func connect() async {
        guard canConnect else { return }
        busy = true
        defer { busy = false }
        let folders = chosen.sorted()
        do { try await authenticate() } catch {
            message = "Connecting needs your Touch ID or login password. Nothing was changed."
            return
        }
        let token: String
        do {
            let r = try await client.global("register_client", [("client_id", .str(Self.claudeCodeID)), ("name", .str("Claude Code")),
                                                                ("binders", .obj(folders.map { ($0, JSONValue.str("propose")) }))])
            guard let t = r["token"]?.stringValue else {
                message = "Sprava did not finish connecting Claude Code. Try again."
                await load()
                return
            }
            token = t
        } catch {
            message = Self.plain(error, "Claude Code could not be connected. Try again in a moment.")
            await load()
            return
        }
        let args = Self.addArguments(token: token)
        let configuration = JSONWriter.pretty(.obj([("mcpServers", .obj([(Self.serverName, .obj([
            ("type", .str("stdio")), ("command", .str(Self.shimPath)),
            ("args", .array([.str("--client"), .str(Self.claudeCodeID)])),
            ("env", .obj([("SPRAVA_CLIENT_TOKEN", .str(token))]))
        ]))]))]))
        registration = nil
        choseByHand = false
        await load()
        await install(Registration(arguments: args, clientID: Self.claudeCodeID, binderPaths: folders, configuration: configuration))
    }

    /// Writes the connection into Claude Code's settings for the person.
    func tryAgain() async {
        guard let pending = registration, !busy else { return }
        busy = true
        defer { busy = false }
        await install(pending)
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
            ? "Setup copied for this Mac only. It clears from the clipboard after 60 seconds."
            : "The setup could not be copied. Try again."
    }

    /// Where Claude Code is installed, if it is; tests put their own program here.
    var claude: () -> URL? = {
        ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude"]
            .map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
    /// Runs Claude Code; tests run their own program.
    var run: @Sendable (URL, [String], TimeInterval) async throws -> ChildRun.Outcome = { program, arguments, timeout in
        try await ChildRun(executable: program, arguments: arguments, timeout: timeout).run()
    }
    var timeout: TimeInterval = 60

    static let byHand = "To finish, add the setup below to ~/.claude.json by hand, keeping the other entries there."

    /// Runs `claude mcp remove` and `claude mcp add` directly, with no shell, so the key never lands in a shell
    /// history file. They run off the main actor and are stopped after `timeout`, so a stalled Claude Code never
    /// leaves the app unresponsive. Whatever goes wrong, the setup stays on the page to add by hand.
    private func install(_ pending: Registration) async {
        guard let path = claude() else {
            registration = pending
            message = "Claude Code was not found on this Mac. " + Self.byHand
            return
        }
        do {
            // Its outcome does not matter: it fails when there is no earlier entry, and the add says what is wrong.
            _ = try? await run(path, Array(Self.removeArguments.dropFirst()), timeout)
            let r = try await run(path, Array(pending.arguments.dropFirst()), timeout)
            switch r.ending {
            case .exited(0):
                registration = nil
                message = "Claude Code is connected. Start a new Claude Code session to use it."
            case .exited:
                let said = String(decoding: r.stderr.isEmpty ? r.stdout : r.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                registration = pending
                message = "Claude Code did not accept the setup" + (said.isEmpty ? ". " : " (\(said.suffix(300))). ") + Self.byHand
            case .timedOut:
                registration = pending
                message = "Claude Code did not finish in \(Int(timeout)) seconds and was stopped. Try again, or add the setup below to ~/.claude.json by hand, keeping the other entries there."
            }
        } catch {
            registration = pending
            message = "Claude Code could not be started. " + Self.byHand
        }
    }

    /// Whether this brain may read the text of documents waiting for a careful reading.
    func setDocuments(_ c: Client, _ allowed: Bool) async {
        do {
            if allowed {
                do { try await authenticate() } catch {
                    message = "Allowing documents needs your Touch ID or login password. Nothing was changed."
                    return
                }
            }
            _ = try await client.global("client_documents", [("client_id", .string(c.id)), ("documents", .bool(allowed))])
            message = nil
        } catch { message = Self.plain(error, "The document setting could not be changed. Try again in a moment.") }
        await load()
    }

    /// Ends a connection at once and withdraws its waiting suggestions; for Claude Code, also removes Sprava's entry
    /// from its settings, so it stops trying to start Sprava.
    func disconnect(_ c: Client) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.global("revoke_client", [("client_id", .string(c.id))])
            message = nil
        } catch let failure as RuntimeClient.Failure where failure.kind == .refused && failure.message.contains("revoked") {
            message = "\(c.name) was disconnected, but some of its suggestions could not be withdrawn. They still wait in their binders."
        } catch {
            message = Self.plain(error, "\(c.name) could not be disconnected. Try again in a moment.")
            await load()
            return
        }
        if c.id == Self.claudeCodeID {
            registration = nil
            choseByHand = false
            if let path = claude() { _ = try? await run(path, Array(Self.removeArguments.dropFirst()), timeout) }
        }
        await load()
    }

    /// What the page says for an error: the runtime's own words only when they are already written for a person
    /// (it is not running, or it did not answer in time); otherwise the sentence for what was being done.
    static func plain(_ error: Error, _ fallback: String) -> String {
        guard let failure = error as? RuntimeClient.Failure else { return fallback }
        switch failure.kind {
        case .notRunning: return failure.message
        case .timedOut: return "Sprava did not answer in time. It may still finish; check this page again before trying again."
        case .refused: return fallback
        }
    }
}

struct BrainsView: View {
    @ObservedObject var model: BrainsModel
    let rows: [ShelfRow]

    /// A binder's name for a folder path, or the folder's own name for a binder no longer on the shelf.
    func names(_ c: BrainsModel.Client) -> String {
        c.binders.keys.map { path in
            rows.first { $0.folder.standardizedFileURL.path == path }?.name ?? URL(fileURLWithPath: path).lastPathComponent
        }.sorted().joined(separator: ", ")
    }

    func documentsToggle(_ c: BrainsModel.Client) -> some View {
        Toggle("May read documents", isOn: Binding(get: { c.documents }, set: { allowed in Task { await model.setDocuments(c, allowed) } }))
            .help("Lets Claude Code read the text of intake documents the clerk recommends a careful reading of, in its binders. For now no intake document is given to it.")
    }

    var body: some View {
        List {
            Section("Claude Code") {
                Text("""
                Connecting adds Sprava to Claude Code's settings for your user account (~/.claude.json). Then start a new \
                Claude Code session in any folder and ask it about these binders: through Sprava it sees each ticked binder's \
                name and how many items are open, overdue or waiting, and it can suggest changes. A suggestion waits in its \
                binder until you approve it.
                """).foregroundStyle(.secondary)
                if let c = model.claudeCode {
                    HStack {
                        Text("Connected: \(names(c))").font(.headline)
                        Spacer()
                        documentsToggle(c)
                        Button("Disconnect") { Task { await model.disconnect(c) } }.disabled(model.busy)
                    }
                }
                ForEach(rows.filter { $0.teka.isAdopted }, id: \.folder) { row in
                    Toggle(row.name, isOn: Binding(get: { model.chosen.contains(row.folder.standardizedFileURL.path) },
                                                   set: { on in model.choose(row.folder, on) }))
                }
                .disabled(model.busy)
                Button(model.claudeCode == nil ? "Connect Claude Code" : "Update") { Task { await model.connect() } }
                    .disabled(!model.canConnect)
                if let pending = model.registration {
                    Text("Setup to add by hand: merge this sprava entry into mcpServers in ~/.claude.json, keeping the other entries. It is for that file, not for Terminal.").font(.caption)
                    Text(pending.configuration).font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Copy Setup") { model.copyRegistration() }
                        Button("Try Again") { Task { await model.tryAgain() } }.disabled(model.busy)
                    }
                }
                if let m = model.message { Text(m).foregroundStyle(.orange) }
                DisclosureGroup("What Sprava runs") {
                    Text("Without a shell, so the key never reaches a shell history file:").font(.caption)
                    Text(BrainsModel.shellLine(BrainsModel.removeArguments)).font(.caption.monospaced())
                    Text(BrainsModel.shellLine(BrainsModel.addArguments(token: "KEY"))).font(.caption.monospaced())
                    Text("KEY is a new secret made each time you connect. Only its fingerprint stays in Sprava; Claude Code keeps the key in its settings.").font(.caption)
                }
            }
            if !model.others.isEmpty {
                Section("Other connections") {
                    ForEach(model.others) { c in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(c.name).font(.headline)
                                Text(names(c)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            documentsToggle(c)
                            Button("Disconnect") { Task { await model.disconnect(c) } }.disabled(model.busy)
                        }
                    }
                }
            }
            Section("Before you connect") {
                Text("""
                Claude Code cannot apply anything through Sprava: every change waits for you. What it reads goes to the \
                model provider Claude Code uses. Claude Code can also read binder folders with its own file tools. In its \
                permission settings, deny Read, Edit and Write on each entire binder folder, on the capture root and on \
                ~/Library/Application Support/Sprava, or use its sandbox controls. Sprava cannot check those settings.
                """).foregroundStyle(.secondary)
            }
        }
        .task { await model.load() }
    }
}
