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
    struct Token: Identifiable, Equatable { let name: String; let saved: Date?; let renewBy: Date?; let renewSoon: Bool; var id: String { name } }
    @Published private(set) var tokens: [Token] = []
    @Published private(set) var activeToken: String?
    @Published var newTokenName = ""
    @Published var newToken = ""
    @Published var chooser = ""
    private var savedChooser = ""
    let client: RuntimeClient
    let authenticate: () async throws -> Void
    init(client: RuntimeClient = RuntimeClient(), authenticate: @escaping () async throws -> Void = {
        guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Enable a private Claude connection in Sprava.") else { throw CancellationError() }
    }) { self.client = client; self.authenticate = authenticate }
    static func installedProgram() -> String {
        ClaudeInstallation.locate()?.path ?? ""
    }
    func load() async {
        do { let status = try await client.global("claude_status", timeout: 5); enabled = status["enabled"] == .bool(true); persistent = status["credential_persistent"] == .bool(true); showAccounts(status); available = true }
        catch { available = false; message = "Sprava could not check Claude. Open Health to check the background connection." }
        checked = true
    }

    /// The lines of the status read that describe the accounts.
    func showAccounts(_ status: JSONObject) {
        tokens = (status["tokens"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue else { return nil }
            return Token(name: name, saved: ISOTime.date(row["saved"]?.stringValue), renewBy: ISOTime.date(row["renew_by"]?.stringValue), renewSoon: row["renew_soon"] == .bool(true))
        }
        activeToken = status["active"]?.stringValue
        // What the person has typed and not saved stays; a status read changes the field only when it holds the saved command.
        let stored = status["chooser"]?.stringValue ?? ""
        if chooser == savedChooser { chooser = stored }
        savedChooser = stored
    }

    func saveToken() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        message = "Checking the token…"
        do {
            try await authenticate()
            let name = newTokenName.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await client.global("claude_token_save", [("name", .str(name)), ("credential", .str(newToken.trimmingCharacters(in: .whitespacesAndNewlines)))], timeout: 150)
            newToken = ""; newTokenName = ""
            message = "Saved the token for “\(name)”."
            showAccounts(try await client.global("claude_status", timeout: 5))
        } catch let failure as RuntimeClient.Failure {
            message = failure.code.flatMap(ClaudeSetupFailure.init(rawValue:))?.message ?? "That token could not be saved. Names use letters, digits and . _ / - only."
        } catch { message = "The token was not saved. It is still in the secure field." }
    }

    func removeToken(_ name: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await authenticate()
            _ = try await client.global("claude_token_remove", [("name", .str(name))], timeout: 15)
            message = "Removed the token for “\(name)”."
            showAccounts(try await client.global("claude_status", timeout: 5))
        } catch { message = "“\(name)” was not removed. Wait for any reply to finish; the last token goes with Disconnect." }
    }

    func saveChooser() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await authenticate()
            _ = try await client.global("claude_chooser_set", [("chooser", .str(chooser))], timeout: 15)
            savedChooser = chooser
            message = chooser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Removed the command." : "Saved the command. It runs for a new conversation, or when an account refuses."
        } catch { message = "The command was not saved." }
    }

    /// The command that prints a subscription token, run by the person in Terminal.
    var setupCommand: String {
        let executable = program.isEmpty ? "claude" : program
        return "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' setup-token"
    }

    /// Why Verify and Enable cannot be pressed yet, naming the step to do; nil when it can. A status read that
    /// failed says so: it is no evidence that a step is missing.
    var enableBlocker: String? {
        if !checked { return "Checking Sprava's background part…" }
        if !available { return "Sprava's background part did not answer, so the setup cannot be checked. Open Health, then Refresh." }
        if program.isEmpty { return "Install native Claude Code, or choose its executable under Claude installation." }
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Paste your subscription token below." }
        return nil
    }

    func copySetupCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupCommand, forType: .string)
    }
    func enable() async {
        guard !busy else { return }
        busy = true; message = "Verifying the private Claude connection…"
        defer { busy = false }
        do {
            try await authenticate()
            let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await client.global("claude_configure", [("program", .str(program)), ("credential", .str(credential))], timeout: 270)
            token = ""
            await load()
            NotificationCenter.default.post(name: .init("Sprava.ClaudeConnectionChanged"), object: nil)
            message = enabled ? "Claude is ready. Open a binder and choose Connect to Claude to start its conversation." : "Refresh the background connection before connecting a binder."
        } catch let failure as RuntimeClient.Failure {
            if let issue = failure.code.flatMap(ClaudeSetupFailure.init(rawValue:)) { message = issue.message }
            else if failure.kind == .timedOut { message = ClaudeSetupFailure.timeout.message }
            else if failure.kind == .notRunning { message = failure.message }
            else { message = ClaudeSetupFailure.unavailable.message }
        } catch {
            message = "Claude setup was cancelled or could not be authorized. Your token is still in the secure field."
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
        Section("Claude assistant") {
            Text("Set up Claude once, then talk with it on each binder's page.")
            if model.enabled {
                Label("Set up. Connect each binder from its own page, where you choose what Claude may read.", systemImage: "checkmark.circle")
                ClaudeTokensView(model: model)
                HStack {
                    Button("Disconnect") { Task { await model.disconnect() } }.disabled(model.busy)
                    Button("Refresh") { Task { await model.load() } }.disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small) }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(model.program.isEmpty ? "Native Claude Code was not found" : "Native Claude Code selected",
                          systemImage: model.program.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                    DisclosureGroup("Claude installation") {
                        TextField("Native Claude executable", text: $model.program).textFieldStyle(.roundedBorder).disabled(model.busy)
                        Text("Sprava uses this executable directly, with its own private settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Subscription token").font(.headline)
                    HStack {
                        Text("Copy this command, run it in Terminal, and sign in with your Claude subscription. Then paste the token below.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Copy Command") { model.copySetupCommand() }.controlSize(.small)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    SecureField("Paste subscription token", text: $model.token).textFieldStyle(.roundedBorder).disabled(model.busy)
                    Text("Sprava keeps it in your Mac's Keychain, and Claude runs in a home of its own.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Connect Claude") { Task { await model.enable() } }.disabled(model.busy || model.enableBlocker != nil)
                            .buttonStyle(.borderedProminent)
                        Button("Refresh") { Task { await model.load() } }.disabled(model.busy)
                        if model.busy { ProgressView().controlSize(.small) }
                    }
                    if !model.busy, let why = model.enableBlocker { Text(why).font(.caption).foregroundStyle(.secondary) }
                    Text("Connection checks send no binder data. You choose what to share on each binder's page.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.message { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
        }
        .task { await model.load() }
    }
}

/// The Claude accounts Sprava holds a token for, each named by the person. Most people have one and never open the second part.
struct ClaudeTokensView: View {
    @ObservedObject var model: ClaudeAccountModel
    private static func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts").font(.headline)
            ForEach(model.tokens) { token in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: token.name + (token.name == model.activeToken ? " (in use)" : ""))
                        if let renew = token.renewBy {
                            Text(token.renewSoon ? "Runs out around \(Self.day(renew)). Make a new token." : "Saved \(token.saved.map(Self.day) ?? ""), lasts until about \(Self.day(renew)).")
                                .font(.caption).foregroundStyle(token.renewSoon ? .orange : .secondary)
                        }
                    }
                    Spacer()
                    if model.tokens.count > 1 { Button("Remove") { Task { await model.removeToken(token.name) } }.controlSize(.small).disabled(model.busy) }
                }
            }
            DisclosureGroup("Add or replace an account") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("In a browser signed in to that Claude account, run the setup command and paste its token here. The same name replaces its token.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $model.newTokenName).textFieldStyle(.roundedBorder).disabled(model.busy)
                    SecureField("Paste subscription token", text: $model.newToken).textFieldStyle(.roundedBorder).disabled(model.busy)
                    HStack {
                        Button("Copy Command") { model.copySetupCommand() }.controlSize(.small)
                        Button("Save Token") { Task { await model.saveToken() } }.controlSize(.small)
                            .disabled(model.busy || model.newTokenName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.newToken.isEmpty)
                    }
                }
            }
            DisclosureGroup("Choose the account with a command") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Optional. A command of yours that prints an account's name. It runs on this Mac, outside Claude's sandbox, for up to 10 seconds, when a conversation starts or an account refuses. Printing nothing, or exit code 75, means no account has quota.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("Command", text: $model.chooser, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced)).disabled(model.busy)
                    Button("Save Command") { Task { await model.saveChooser() } }.controlSize(.small).disabled(model.busy)
                }
            }
        }
    }
}
