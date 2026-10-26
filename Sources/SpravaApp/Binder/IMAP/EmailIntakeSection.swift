import SwiftUI

/// The binder page's email intake: a three-step setup (server, account, label) that collapses to one status line
/// once the binder is connected. Built in, not a plugin; integrations.md describes the plugin model for later.
struct EmailIntakeSection: View {
    let folder: URL
    @StateObject private var model: EmailIntakeModel
    @State private var expanded: Bool
    @State private var filters = false

    init(folder: URL, model: @autoclosure @escaping () -> EmailIntakeModel = EmailIntakeModel(), expanded: Bool = false) {
        self.folder = folder
        _model = StateObject(wrappedValue: model())
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.status.installed {
                        Note(symbol: "exclamationmark.triangle.fill", tint: .orange,
                             text: "Email intake runs on Homebrew's Python 3. Install it in Terminal with: brew install python. Then reopen this binder.")
                    }
                    if model.settingUp { setup } else { connected }
                    if let message = model.pageMessage { Text(verbatim: message).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 6)
            } label: {
                HStack {
                    Text("Email intake (IMAP)")
                    Spacer()
                    badge
                }
            }
        }
        .task(id: folder) {
            await model.show(folder)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3)); if Task.isCancelled { break }
                if !model.busy { await model.show(folder) }
            }
        }
    }

    @ViewBuilder private var badge: some View {
        if model.status.enabled && model.status.needsPassword {
            Label("Needs password", systemImage: "circle.fill").labelStyle(Badge(tint: .orange))
        } else if model.status.enabled {
            Label(model.status.running ? "Checking" : "Connected", systemImage: "circle.fill").labelStyle(Badge(tint: .green))
        } else if model.status.configured {
            Label("Stopped", systemImage: "circle.fill").labelStyle(Badge(tint: .secondary))
        }
    }

    // MARK: Connected

    @ViewBuilder private var connected: some View {
        let s = model.status
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: s.mailbox ?? "").font(.headline)
            Text(verbatim: "\(s.user ?? "") · \(s.host ?? ""):\(s.port.map(String.init) ?? "") \(s.security?.label ?? "")")
                .foregroundStyle(.secondary)
        }
        if s.needsPassword {
            Note(symbol: "key.fill", tint: .orange, text: "Sprava restarted and needs this account's password again to keep checking.")
            HStack {
                SecureField("Password", text: $model.password).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .onSubmit { Task { await model.resume() } }
                Button("Resume") { Task { await model.resume() } }.disabled(model.password.isEmpty || model.busy)
            }
        } else if let message = s.message {
            Text(verbatim: message).foregroundStyle(.secondary)
        }
        HStack(spacing: 8) {
            Button("Check now") { Task { await model.syncNow() } }.disabled(model.busy || s.running || s.needsPassword)
            Button("Change…") { model.beginChange() }.disabled(model.busy || s.running)
            Button("Disconnect") { Task { await model.disconnect() } }.disabled(model.busy)
            if s.running || model.busy { ProgressView().controlSize(.small) }
        }
        Text("Read-only: mail stays unread and unchanged on the server.").font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Setup

    @ViewBuilder private var setup: some View {
        if !model.editing, model.status.configured, let message = model.status.message {
            Note(symbol: "exclamationmark.triangle.fill", tint: .orange, text: message)
        }
        Text("Brings new mail from one folder or label into this binder's intake. Read-only: mail stays unread and unchanged on the server.")
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Step(number: 1, title: "Server", done: model.serverReady, active: true) { serverStep }
        Step(number: 2, title: "Account", done: model.folders != nil, active: model.serverReady) { accountStep }
        Step(number: 3, title: "Folder or label", done: false, active: model.folders != nil) { labelStep }
        if model.editing {
            Button("Cancel") { model.cancelChange() }.disabled(model.busy)
        }
    }

    @ViewBuilder private var serverStep: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                FieldLabel("Host")
                HStack {
                    TextField("Host", text: $model.host, prompt: Text(verbatim: "imap.example.com or 127.0.0.1"))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 280).autocorrectionDisabled()
                        .onSubmit { Task { await model.check() } }
                    Button("Check") { Task { await model.check() } }
                        .disabled(model.busy || model.host.trimmingCharacters(in: .whitespaces).isEmpty)
                    if model.activity == .checking { ProgressView().controlSize(.small) }
                }
            }
            GridRow {
                FieldLabel("Security")
                HStack {
                    Picker("Security", selection: Binding(get: { model.security }, set: { model.chooseSecurity($0) })) {
                        ForEach(EmailIntakeModel.Security.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Text("Port").foregroundStyle(.secondary)
                    TextField("993", text: Binding(get: { model.port }, set: { model.choosePort($0.filter(\.isNumber)) }))
                        .textFieldStyle(.roundedBorder).frame(width: 64)
                }
            }
        }
        if let message = model.serverMessage {
            switch (model.server?.result, model.server?.loopback) {
            case ("ok", _): Note(symbol: "checkmark.circle.fill", tint: .green, text: message)
            case ("untrusted", true): Note(symbol: "exclamationmark.shield.fill", tint: .orange, text: message)
            default: Note(symbol: "xmark.octagon.fill", tint: .red, text: message)
            }
        }
        if let server = model.server, server.result == "untrusted", server.loopback, let fingerprint = server.fingerprint {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "SHA-256  " + EmailIntakeModel.grouped(fingerprint))
                    .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if model.trusted {
                    Label("Trusted for this binder's connection", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Trust this certificate") { model.trust() }
                }
            }
            .padding(.leading, 2)
        }
    }

    @ViewBuilder private var accountStep: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                FieldLabel("Username")
                TextField("Username", text: $model.user, prompt: Text(verbatim: "you@example.com"))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280).autocorrectionDisabled()
            }
            GridRow {
                FieldLabel("Password")
                HStack {
                    SecureField(model.savedPasswordApplies ? "Saved" : (model.server?.loopback == true ? "The bridge's password" : "Password or app password"),
                                text: $model.password)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 280).onSubmit { Task { await model.signIn() } }
                    Button("Sign in") { Task { await model.signIn() } }.disabled(!model.canSignIn)
                    if model.activity == .signingIn { ProgressView().controlSize(.small) }
                }
            }
        }
        if let message = model.accountMessage {
            Note(symbol: model.folders != nil ? "checkmark.circle.fill" : "xmark.octagon.fill", tint: model.folders != nil ? .green : .red, text: message)
        }
    }

    @ViewBuilder private var labelStep: some View {
        if let folders = model.folders, !folders.isEmpty {
            if folders.count > 8 {
                TextField("Filter folders", text: $model.filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            }
            FolderList(names: model.visibleFolders, selection: $model.mailbox)
            Toggle("Also import mail already in this folder", isOn: $model.includeExisting)
            Button { filters.toggle() } label: {
                Label("More filters", systemImage: filters ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.borderless)
            if filters || !model.sender.isEmpty || !model.subject.isEmpty || !model.search.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow { FieldLabel("From contains"); TextField("From contains", text: $model.sender, prompt: Text("Optional")).textFieldStyle(.roundedBorder).frame(maxWidth: 280) }
                    GridRow { FieldLabel("Subject contains"); TextField("Subject contains", text: $model.subject, prompt: Text("Optional")).textFieldStyle(.roundedBorder).frame(maxWidth: 280) }
                    GridRow { FieldLabel("IMAP SEARCH"); TextField("IMAP SEARCH", text: $model.search, prompt: Text(verbatim: "Optional, e.g. SINCE 01-Oct-2026")).textFieldStyle(.roundedBorder).frame(maxWidth: 280) }
                }
                Text("From and Subject are matched on the server and again on the decoded message.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(model.editing ? "Save changes" : "Connect binder") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent).disabled(!model.canConnect)
                if model.activity == .connecting { ProgressView().controlSize(.small) }
            }
            if let message = model.connectMessage {
                Note(symbol: "xmark.octagon.fill", tint: .red, text: message)
            }
        } else {
            Text("Sign in to see the account's folders and labels.").foregroundStyle(.secondary)
        }
    }
}

/// One numbered setup step. A step that cannot be used yet is dimmed and disabled, never hidden, so the
/// whole path is visible from the start.
private struct Step<Content: View>: View {
    let number: Int, title: String, done: Bool, active: Bool
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : active ? Color.accentColor : Color.secondary.opacity(0.4)).frame(width: 20, height: 20)
                if done { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) }
                else { Text("\(number)").font(.caption.bold()).foregroundStyle(.white) }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content
            }
        }
        .opacity(active ? 1 : 0.45)
        .disabled(!active)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title)\(done ? ", done" : "")")
    }
}

/// The account's folders as one-choice rows, scrolling past about eight.
private struct FolderList: View {
    let names: [String]
    @Binding var selection: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(names, id: \.self) { name in
                    Button { selection = name } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selection == name ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selection == name ? Color.accentColor : Color.secondary)
                            Text(verbatim: name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .background(selection == name ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == name ? .isSelected : [])
                }
                if names.isEmpty { Text("No folder matches.").foregroundStyle(.secondary).padding(6) }
            }
        }
        .frame(maxWidth: 420, maxHeight: names.count > 8 ? 230 : nil)
        .fixedSize(horizontal: false, vertical: names.count <= 8)
    }
}

/// A form label with the width every step shares, so their fields line up.
private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).foregroundStyle(.secondary).frame(minWidth: 72, alignment: .leading) }
}

/// A status line with its symbol, for results and warnings inside the setup.
private struct Note: View {
    let symbol: String, tint: Color, text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

private struct Badge: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(tint)
            configuration.title.font(.caption).foregroundStyle(.secondary)
        }
    }
}
