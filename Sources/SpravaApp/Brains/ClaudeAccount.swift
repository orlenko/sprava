import AppKit
import Combine
import Foundation
import LocalAuthentication
import Services
import SpravaKit
import SwiftUI

@MainActor
final class ClaudeAccountModel: ObservableObject {
    @Published var token = ""
    @Published var program = ClaudeAccountModel.installedProgram()
    @Published private(set) var available = false
    @Published private(set) var enabled = false
    @Published private(set) var persistent = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    let client: RuntimeClient
    let authenticate: () async throws -> Void
    init(client: RuntimeClient = RuntimeClient(), authenticate: @escaping () async throws -> Void = {
        guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Enable a private Claude connection in Sprava.") else { throw CancellationError() }
    }) { self.client = client; self.authenticate = authenticate }
    static func installedProgram() -> String {
        [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
    func load() async {
        do { let status = try await client.global("claude_status", timeout: 5); enabled = status["enabled"] == .bool(true); persistent = status["credential_persistent"] == .bool(true); available = true }
        catch { available = false; message = "Sprava could not check Claude. Open Health to check the background connection." }
    }
    func enable() async {
        guard !busy else { return }
        busy = true; message = "Verifying the private Claude connection…"
        defer { busy = false }
        do {
            try await authenticate()
            let credential = token; token = ""
            _ = try await client.global("claude_configure", [("program", .str(program)), ("credential", .str(credential))], timeout: 270)
            await load()
            NotificationCenter.default.post(name: .init("Sprava.ClaudeConnectionChanged"), object: nil)
            message = enabled ? "Claude is ready. Connect a binder on its Conversation section to choose what it may read." : "Refresh the background connection before connecting a binder."
        } catch {
            message = "Claude could not be enabled. Check Claude Code, the subscription token and Keychain access. If verification timed out, Refresh before trying again."
        }
    }
    func disconnect() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { _ = try await client.global("claude_disconnect", timeout: 30); enabled = false; NotificationCenter.default.post(name: .init("Sprava.ClaudeConnectionChanged"), object: nil); message = "Claude is disconnected; saved app conversations remain." }
        catch { message = "Claude could not be disconnected. Check the connection before trying again." }
    }
}

struct ClaudeAccountView: View {
    @ObservedObject var model: ClaudeAccountModel
    var body: some View {
        Section("Claude in Sprava") {
            Text("One private Claude conversation per binder. Ask about its tasks and sources, or draft an email. You confirm suggested tasks; Sprava never sends email.")
            Text("Requires a Claude subscription and Claude Code. Run claude setup-token privately in Terminal, then paste its token here. Sprava keeps the token in your Mac's Keychain and uses an isolated home.").font(.caption).foregroundStyle(.secondary)
            TextField("Claude executable", text: $model.program).disabled(model.busy)
            SecureField("Claude subscription setup token", text: $model.token).disabled(model.busy)
            Text("Verify sends two small fixed connection checks across a restart to Anthropic with no binder data. Sharing each binder is a separate choice. Each conversation process has a $2 list-price-equivalent cap; that is not a subscription charge estimate.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Verify and Enable Claude") { Task { await model.enable() } }.disabled(model.busy || !model.available || model.token.isEmpty || model.program.isEmpty)
                Button("Refresh") { Task { await model.load() } }.disabled(model.busy)
                if model.enabled { Button("Disconnect") { Task { await model.disconnect() } }.disabled(model.busy) }
                if model.busy { ProgressView().controlSize(.small) }
            }
            if let message = model.message { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
        }
        .task { await model.load() }
    }
}
