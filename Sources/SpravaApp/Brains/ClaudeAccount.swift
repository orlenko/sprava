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
    /// How the message reads, and which control it answers, so it appears next to that control.
    enum MessageKind { case progress, done, warning, failure }
    enum MessagePlace { case setup, account, chooser }
    @Published private(set) var messageKind = MessageKind.progress
    @Published private(set) var messagePlace = MessagePlace.setup
    private func say(_ text: String?, _ kind: MessageKind, at place: MessagePlace = .setup) { message = text; messageKind = kind; messagePlace = place }
    @Published var showsInstallation = false
    @Published var showsAddAccount = false
    @Published var showsChooser = false
    /// What the first token is called; left empty it is "main".
    @Published var tokenName = ""
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
        catch { available = false; say("Sprava could not check Claude. Open Health to check the background connection.", .failure) }
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

    /// What is wrong with a name typed for an account; nil when it can be used.
    static func nameProblem(_ typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || ClaudeAccountName.isValid(name) ? nil : "A name uses letters, digits and . _ / - only, up to 64 characters."
    }

    func saveToken() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        say("Checking the token…", .progress, at: .account)
        do {
            try await authenticate()
            let name = newTokenName.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await client.global("claude_token_save", [("name", .str(name)), ("credential", .str(newToken.trimmingCharacters(in: .whitespacesAndNewlines)))], timeout: 150)
            newToken = ""; newTokenName = ""
            say("Saved the token for “\(name)”.", .done, at: .account)
            showAccounts(try await client.global("claude_status", timeout: 5))
        } catch let failure as RuntimeClient.Failure {
            say(failure.code.flatMap(ClaudeSetupFailure.init(rawValue:))?.message ?? "That token could not be saved. Wait for any reply to finish, then try again.", .failure, at: .account)
        } catch { say("The token was not saved. It is still in the field.", .failure, at: .account) }
    }

    func removeToken(_ name: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await authenticate()
            _ = try await client.global("claude_token_remove", [("name", .str(name))], timeout: 15)
            say("Removed the token for “\(name)”.", .done, at: .account)
            showAccounts(try await client.global("claude_status", timeout: 5))
        } catch { say("“\(name)” was not removed. Wait for any reply to finish; the last token goes with Disconnect.", .failure, at: .account) }
    }

    func saveChooser() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await authenticate()
            _ = try await client.global("claude_chooser_set", [("chooser", .str(chooser))], timeout: 15)
            savedChooser = chooser
            say(chooser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Removed the command." : "Saved the command. It runs for a new conversation, or when an account refuses.", .done, at: .chooser)
        } catch { say("The command was not saved.", .failure, at: .chooser) }
    }

    /// The command that prints a subscription token, run by the person in Terminal.
    var setupCommand: String {
        let executable = program.isEmpty ? "claude" : program
        return "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' setup-token"
    }

    /// What stops setup that the person cannot see from the fields themselves; nil when nothing does.
    var setupProblem: String? {
        if !checked { return "Checking Sprava's background part…" }
        if !available { return "Sprava's background part did not answer, so the setup cannot be checked. Open Health, then Check Again." }
        if program.isEmpty { return "Install native Claude Code, or choose its executable under Claude installation." }
        return nameProblem
    }
    var nameProblem: String? { Self.nameProblem(tokenName) }
    /// Why Connect cannot be pressed yet, naming the step to do; nil when it can.
    var enableBlocker: String? {
        setupProblem ?? (token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Paste your subscription token above." : nil)
    }

    func copySetupCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupCommand, forType: .string)
    }
    func enable() async {
        guard !busy else { return }
        busy = true; say("Checking the connection…", .progress)
        defer { busy = false }
        do {
            try await authenticate()
            let credential = token.trimmingCharacters(in: .whitespacesAndNewlines), name = tokenName.trimmingCharacters(in: .whitespacesAndNewlines)
            var fields: [(String, JSONValue)] = [("program", .str(program)), ("credential", .str(credential))]
            if !name.isEmpty { fields.append(("name", .str(name))) }
            let answer = try await client.global("claude_configure", fields, timeout: 270)
            token = ""; tokenName = ""
            await load()
            NotificationCenter.default.post(name: .init("Sprava.ClaudeConnectionChanged"), object: nil)
            if !enabled { say("Connected, but Sprava's background part did not confirm it. Choose Check Again before connecting a binder.", .warning) }
            else if answer["at_limit"] == .bool(true) { say("Connected. The token is good, but this Claude account has reached its usage limit, so Claude cannot answer until it resets. You can add another account below.", .warning, at: .account) }
            else { say("Claude is ready. Open a binder and choose Connect to Claude to start its conversation.", .done, at: .account) }
        } catch let failure as RuntimeClient.Failure {
            if let issue = failure.code.flatMap(ClaudeSetupFailure.init(rawValue:)) { say(issue.message, .failure) }
            else if failure.kind == .timedOut { say(ClaudeSetupFailure.timeout.message, .failure) }
            else if failure.kind == .notRunning { say(failure.message, .failure) }
            else { say(ClaudeSetupFailure.unavailable.message, .failure) }
        } catch {
            say("Setup was cancelled or could not be authorized. Your token is still in the field.", .failure)
        }
    }
    func disconnect() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { _ = try await client.global("claude_disconnect", timeout: 30); enabled = false; NotificationCenter.default.post(name: .init("Sprava.ClaudeConnectionChanged"), object: nil); say("Claude is disconnected; saved app conversations remain.", .done) }
        catch { say("Claude could not be disconnected. Check the connection before trying again.", .failure, at: .account) }
    }
}

struct ClaudeAccountView: View {
    @ObservedObject var model: ClaudeAccountModel
    var body: some View {
        Section("Claude assistant") {
            if model.enabled { connected } else { setup }
        }
        .task { await model.load() }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connected. Talk with Claude on each binder's page, where you choose what it may read.", systemImage: "checkmark.circle.fill")
                .labelStyle(ClaudeStatusLabelStyle(color: .green))
            ClaudeTokensView(model: model)
            Button("Disconnect") { Task { await model.disconnect() } }.disabled(model.busy)
        }
        .padding(.vertical, 4)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect your Claude subscription. Then talk with Claude on each binder's page, where you choose what it may read.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Get a token").font(.headline)
                Text("Copy this command and run it in Terminal. It opens your browser, so if you have several Claude accounts, use the browser profile signed in to the one you want.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Copy Command") { model.copySetupCommand() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("2. Paste it here").font(.headline)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Token").gridColumnAlignment(.trailing)
                        SecureField("Subscription token", text: $model.token).textFieldStyle(.roundedBorder).disabled(model.busy)
                    }
                    GridRow {
                        Text("Name")
                        TextField("main", text: $model.tokenName).textFieldStyle(.roundedBorder).disabled(model.busy)
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Text("Optional. Worth setting if you will add more than one account.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Connect Claude") { Task { await model.enable() } }.disabled(model.busy || model.enableBlocker != nil)
                    .buttonStyle(.borderedProminent)
                if model.busy { ProgressView().controlSize(.small) }
                if !model.busy, !model.available || model.messageKind == .failure {
                    Button("Check Again") { Task { await model.load() } }
                }
            }
            if !model.busy, let why = model.setupProblem { ClaudeStatusLine(text: why, kind: .warning) }
            if let message = model.message, model.messagePlace == .setup { ClaudeStatusLine(text: message, kind: model.messageKind) }
            Text("Sprava keeps the token in your Mac's Keychain. Connecting sends no binder data.")
                .font(.callout).foregroundStyle(.secondary)
            ClaudeExpandingRow(title: "Claude installation", open: $model.showsInstallation)
            if model.showsInstallation {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Native Claude executable", text: $model.program).textFieldStyle(.roundedBorder).disabled(model.busy)
                    Text("Sprava runs this program directly, with private settings of its own.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A row that opens what is under it. A DisclosureGroup in a List shows its arrow only under the pointer, so nothing says it opens.
struct ClaudeExpandingRow: View {
    let title: String
    @Binding var open: Bool
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12)
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Open" : "Closed")
    }
}

/// An answer to something the person just did, set apart from the page's explanations by its icon, color and ground.
struct ClaudeStatusLine: View {
    let text: String
    let kind: ClaudeAccountModel.MessageKind
    private var color: Color {
        switch kind { case .progress: .secondary; case .done: .green; case .warning: .orange; case .failure: .red }
    }
    private var symbol: String {
        switch kind { case .progress: "hourglass"; case .done: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .failure: "xmark.octagon.fill" }
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(verbatim: text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(kind == .progress ? 0.08 : 0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ClaudeStatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(color)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
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
                                .font(.callout).foregroundStyle(token.renewSoon ? .orange : .secondary)
                        }
                    }
                    Spacer()
                    if model.tokens.count > 1 { Button("Remove") { Task { await model.removeToken(token.name) } }.disabled(model.busy) }
                }
            }
            if let message = model.message, model.messagePlace == .account { ClaudeStatusLine(text: message, kind: model.messageKind) }
            ClaudeExpandingRow(title: "Add or replace an account", open: $model.showsAddAccount)
            if model.showsAddAccount {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Copy the command and run it in Terminal, in the browser profile signed in to that account. A name you have used already replaces its token.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Copy Command") { model.copySetupCommand() }
                    TextField("Name", text: $model.newTokenName).textFieldStyle(.roundedBorder).disabled(model.busy)
                    SecureField("Subscription token", text: $model.newToken).textFieldStyle(.roundedBorder).disabled(model.busy)
                    if let problem = ClaudeAccountModel.nameProblem(model.newTokenName) { ClaudeStatusLine(text: problem, kind: .warning) }
                    Button("Save Token") { Task { await model.saveToken() } }
                        .disabled(model.busy || model.newTokenName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.newToken.isEmpty || ClaudeAccountModel.nameProblem(model.newTokenName) != nil)
                }
            }
            ClaudeExpandingRow(title: "Choose the account with a command", open: $model.showsChooser)
            if model.showsChooser {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Optional. A command of yours that prints an account's name. It runs on this Mac, outside Claude's sandbox, for up to 10 seconds, when a conversation starts or an account refuses. Printing nothing, or exit code 75, means no account has quota.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("Command", text: $model.chooser, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced)).disabled(model.busy)
                    Button("Save Command") { Task { await model.saveChooser() } }.disabled(model.busy)
                    if let message = model.message, model.messagePlace == .chooser { ClaudeStatusLine(text: message, kind: model.messageKind) }
                }
            }
        }
    }
}
