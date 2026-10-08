import AppKit
import Combine
import SpravaCore
import SwiftUI

/// "Connect a brain" (architecture 7.5; mvp.md feature 10): register Claude Code for chosen binders, show the
/// exact registration once, and run it for the person with no shell. Revoke is one click.
@MainActor
final class BrainsModel: ObservableObject {
    struct Client: Identifiable { let id: String; let name: String; let binders: [String: String]; let documents: Bool }

    @Published var clients: [Client] = []
    @Published var chosen: Set<URL> = []
    @Published var clientID = "claude-code-1"
    @Published var registration: [String]?
    @Published var message: String?
    let client = RuntimeClient()

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

    func register() {
        let scope = chosen.map { ($0.standardizedFileURL.path, JSONValue.str("propose")) }
        Task {
            do {
                let r = try await client.global("register_client", [("client_id", .string(clientID)), ("name", .str("Claude Code")),
                                                                    ("binders", .obj(scope))])
                guard let token = r["token"]?.stringValue else { return }
                // The exact command, every argument shown (SEP-1024); --scope user so no .mcp.json lands in a folder.
                registration = ["claude", "mcp", "add", "--scope", "user", "--transport", "stdio",
                                "--env", "SPRAVA_CLIENT_TOKEN=\(token)", "sprava", "--", Self.shimPath, "--client", clientID]
                message = nil
                await load()
            } catch { message = "\(error)" }
        }
    }

    /// Runs `claude mcp add` directly, with no shell, so the token never lands in a shell history file.
    func runRegistration() {
        guard let args = registration else { return }
        let candidates = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude"]
            .map { ($0 as NSString).expandingTildeInPath }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            message = "Claude Code was not found. Paste the command above into Terminal yourself."
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            message = task.terminationStatus == 0 ? "Claude Code is connected. Restart its session to see Sprava's tools."
                                                  : "claude mcp add failed: \(out.prefix(300))"
            if task.terminationStatus == 0 { registration = nil }
        } catch { message = "\(error)" }
    }

    /// Whether this brain may read the text of documents waiting for a careful reading.
    func setDocuments(_ c: Client, _ allowed: Bool) {
        Task {
            do { _ = try await client.global("client_documents", [("client_id", .string(c.id)), ("documents", .bool(allowed))]) } catch { message = "\(error)" }
            await load()
        }
    }

    func revoke(_ c: Client) {
        Task {
            do { _ = try await client.global("revoke_client", [("client_id", .string(c.id))]) } catch { message = "\(error)" }
            await load()
        }
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
                file tools; deny Edit and Write on each binder's catalog.json and .sprava/ in its permission settings.
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
                        Toggle("May read documents", isOn: Binding(get: { c.documents }, set: { model.setDocuments(c, $0) }))
                            .help("Lets this brain read the text of intake documents the clerk recommends a careful reading of, in its binders.")
                        Button("Revoke") { model.revoke(c) }
                    }
                }
            }
            Section("Connect Claude Code") {
                ForEach(rows.filter { $0.teka.isAdopted }, id: \.folder) { row in
                    Toggle(row.name, isOn: Binding(get: { model.chosen.contains(row.folder) },
                                                   set: { on in if on { model.chosen.insert(row.folder) } else { model.chosen.remove(row.folder) } }))
                }
                TextField("Client id", text: $model.clientID)
                Button("Create Registration") { model.register() }.disabled(model.chosen.isEmpty)
                if let args = model.registration {
                    Text("Shown once. This is the exact command:").font(.caption)
                    Text(args.joined(separator: " ")).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Run It for Me") { model.runRegistration() }
                }
                if let m = model.message { Text(m).foregroundStyle(.orange) }
            }
        }
        .task { await model.load() }
    }
}
