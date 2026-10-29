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
    /// Set once the first status read has finished, so the page says "checking" until then, not "did not answer".
    @Published private(set) var checked = false
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
        checked = true
    }

    /// The command that prints a subscription token, run by the person in Terminal.
    static let setupCommand = "claude setup-token"

    /// Why Verify and Enable cannot be pressed yet, naming the step to do; nil when it can. A status read that
    /// failed says so: it is no evidence that a step is missing.
    var enableBlocker: String? {
        if !checked { return "Checking Sprava's background part…" }
        if !available { return "Sprava's background part did not answer, so the setup cannot be checked. Open Health, then Refresh." }
        if program.isEmpty { return "Step 1: enter where Claude Code is installed." }
        if token.isEmpty { return "Step 3: paste the token from step 2." }
        return nil
    }

    func copySetupCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.setupCommand, forType: .string)
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
            Text("Talk with each binder: ask about its to-dos and documents, or have a draft written. The conversation on a binder's page uses this. You confirm suggested tasks; Sprava never sends email.")
            if model.enabled {
                Label("Set up. Connect each binder from its own page, where you choose what Claude may read.", systemImage: "checkmark.circle")
                HStack {
                    Button("Disconnect") { Task { await model.disconnect() } }.disabled(model.busy)
                    Button("Refresh") { Task { await model.load() } }.disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small) }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Claude Code on this Mac").font(.headline)
                    Text(model.program.isEmpty ? "Not found. Install Claude Code, or enter where it is:" : "Found. Change the path only if you use another copy:")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Path to claude", text: $model.program).disabled(model.busy)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("2. Get a token").font(.headline)
                    HStack {
                        Text("In Terminal, run \(ClaudeAccountModel.setupCommand) and sign in with your Claude subscription. It prints a token.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Copy Command") { model.copySetupCommand() }.controlSize(.small)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("3. Paste the token").font(.headline)
                    SecureField("Token from step 2", text: $model.token).disabled(model.busy)
                    Text("Sprava keeps it in your Mac's Keychain, and Claude runs in a home of its own.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("4. Verify").font(.headline)
                    HStack {
                        Button("Verify and Enable Claude") { Task { await model.enable() } }.disabled(model.busy || model.enableBlocker != nil)
                        Button("Refresh") { Task { await model.load() } }.disabled(model.busy)
                        if model.busy { ProgressView().controlSize(.small) }
                    }
                    if !model.busy, let why = model.enableBlocker { Text(why).font(.caption).foregroundStyle(.secondary) }
                    Text("Verify sends two small fixed checks to Anthropic, with no binder data. Each conversation process has a $2 list-price-equivalent cap; that is not a subscription charge estimate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.message { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
        }
        .task { await model.load() }
    }
}
