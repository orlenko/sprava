import Combine
import Foundation
import LocalAuthentication
import SpravaKit

/// The binder's email intake setup: server, then account, then the folder or label to read. Each step unlocks the
/// next, and changing an earlier answer clears what depended on it. The password is held only until the runtime
/// takes it (for the Keychain, or its memory in a development build), then cleared.
@MainActor
final class EmailIntakeModel: ObservableObject {
    enum Security: String, CaseIterable, Identifiable {
        case tls, starttls
        var id: String { rawValue }
        var label: String { self == .tls ? "SSL/TLS" : "STARTTLS" }
        var port: Int { self == .tls ? 993 : 143 }
    }
    /// What the server check found, for the host, security and port it was made with.
    struct ServerCheck: Equatable {
        let host: String, security: Security, port: Int
        let result: String
        let fingerprint: String?
        let loopback: Bool
        let attempts: [(security: Security, port: Int, result: String)]
        static func == (a: ServerCheck, b: ServerCheck) -> Bool {
            a.host == b.host && a.security == b.security && a.port == b.port && a.result == b.result && a.fingerprint == b.fingerprint
        }
    }
    /// The runtime's view of this binder's connection.
    struct Status: Equatable {
        var installed = true, enabled = false, running = false, needsPassword = false
        var host: String?, port: Int?, security: Security?, pin: String?, user: String?
        var mailbox: String?, sender = "", subject = "", search = "", includeExisting = true
        var message: String?
        var configured: Bool { host != nil }
    }
    enum Activity { case checking, signingIn, connecting, working }

    // Step 1
    @Published var host = "" { didSet { if host != oldValue { serverChanged(); chosenByHand = false } } }
    @Published var security = Security.tls { didSet { if security != oldValue { serverChanged() } } }
    @Published var port = "993" { didSet { if port != oldValue { serverChanged() } } }
    @Published private(set) var server: ServerCheck?
    @Published private(set) var trusted = false
    @Published private(set) var serverMessage: String?
    // Step 2
    @Published var user = "" { didSet { if user != oldValue { folders = nil } } }
    @Published var password = ""
    @Published private(set) var folders: [String]?
    @Published private(set) var accountMessage: String?
    // Step 3
    @Published var mailbox: String?
    @Published var filter = ""
    @Published var includeExisting = true
    @Published var sender = ""
    @Published var subject = ""
    @Published var search = ""
    @Published private(set) var connectMessage: String?
    // Connected
    @Published private(set) var status = Status()
    @Published private(set) var activity: Activity?
    @Published private(set) var editing = false
    @Published private(set) var pageMessage: String?

    private(set) var folder: URL?
    /// Set when the person picks the security or port, so Check tries exactly that instead of the likely ports.
    private var chosenByHand = false
    private var loading = false
    let client: RuntimeClient
    let authenticate: () async throws -> Void

    init(client: RuntimeClient = RuntimeClient(), authenticate: @escaping () async throws -> Void = {
        guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Connect this binder to the email account.") else { throw CancellationError() }
    }) { self.client = client; self.authenticate = authenticate }

    var busy: Bool { activity != nil }
    var settingUp: Bool { !status.enabled || editing }
    /// The server answered and, for a self-signed bridge on this Mac, the person trusted its certificate.
    var serverReady: Bool {
        guard let server, server.host == normalizedHost, server.security == security, server.port == Int(port) else { return false }
        return server.result == "ok" || (server.result == "untrusted" && server.loopback && trusted)
    }
    var canSignIn: Bool { serverReady && !user.isEmpty && (!password.isEmpty || savedPasswordApplies) && !busy }
    var canConnect: Bool { serverReady && folders != nil && mailbox != nil && !busy && status.installed }
    /// While changing a connection, an empty password means the one Sprava already keeps for the same account.
    var savedPasswordApplies: Bool {
        editing && status.host == normalizedHost && status.port == Int(port) && status.security == security && status.user == user
    }
    var visibleFolders: [String] {
        guard let folders else { return [] }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? folders : folders.filter { $0.localizedCaseInsensitiveContains(needle) }
    }
    private var normalizedHost: String { host.trimmingCharacters(in: .whitespaces).lowercased() }

    func chooseSecurity(_ value: Security) {
        chosenByHand = true; security = value; port = String(value.port)
    }
    func choosePort(_ value: String) { chosenByHand = true; port = value }
    func trust() { if server?.loopback == true, server?.result == "untrusted" { trusted = true; serverMessage = nil } }

    func show(_ folder: URL) async {
        if self.folder != folder { reset(); self.folder = folder }
        await refresh(prefill: status == Status())
    }

    func check() async {
        guard !busy, let folder, !normalizedHost.isEmpty else { return }
        activity = .checking; defer { activity = nil }
        serverMessage = nil
        var fields: [(String, JSONValue)] = [("host", .str(normalizedHost))]
        if chosenByHand, let port = Int(port) { fields += [("security", .str(security.rawValue)), ("port", .int(port))] }
        do {
            let r = try await client.command("imap_probe", binder: folder, fields, timeout: 90)
            guard self.folder == folder, let found = Self.serverCheck(r) else { return }
            loading = true
            security = found.security; port = String(found.port)
            loading = false
            server = found; trusted = false; folders = nil; mailbox = nil
            serverMessage = Self.describe(found)
        } catch {
            if self.folder == folder { serverMessage = (error as? RuntimeClient.Failure)?.message ?? "Sprava could not check the server." }
        }
    }

    func signIn() async {
        guard canSignIn, let folder else { return }
        activity = .signingIn; defer { activity = nil }
        accountMessage = nil
        do {
            var fields = accountFields()
            if !password.isEmpty { fields.append(("password", .str(password))) }
            let r = try await client.command("imap_folders", binder: folder, fields, timeout: 60)
            guard self.folder == folder else { return }
            let names = (r["folders"]?.arrayValue ?? []).compactMap(\.stringValue)
            folders = names
            if let current = mailbox, !names.contains(current) { mailbox = nil }
            if mailbox == nil, let saved = status.mailbox, names.contains(saved) { mailbox = saved }
            accountMessage = names.isEmpty ? "Signed in, but the account shows no folders Sprava can read." : "Signed in. \(names.count == 1 ? "1 folder" : "\(names.count) folders")."
        } catch {
            if self.folder == folder { folders = nil; accountMessage = (error as? RuntimeClient.Failure)?.message ?? "Sprava could not sign in." }
        }
    }

    func connect() async {
        guard canConnect, let folder, let mailbox else { return }
        activity = .connecting; defer { activity = nil }
        connectMessage = nil
        do {
            try await authenticate()
            guard self.folder == folder else { return }
            var fields = accountFields() + [("mailbox", .str(mailbox)), ("include_existing", .bool(includeExisting)),
                                            ("sender", .str(sender)), ("subject", .str(subject)), ("search", .str(search))]
            if !password.isEmpty { fields.append(("password", .str(password))) }
            let r = try await client.command("imap_configure", binder: folder, fields, timeout: 20)
            guard self.folder == folder else { return }
            password = ""; editing = false
            status = Self.status(r)
        } catch is CancellationError {
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
        } catch {
            if self.folder == folder { connectMessage = (error as? RuntimeClient.Failure)?.message ?? "Sprava could not connect this binder." }
        }
    }

    /// After a restart of a development build, the runtime no longer holds the password.
    func resume() async {
        guard !busy, !password.isEmpty, let folder else { return }
        await perform("imap_password", folder: folder, [("password", .str(password))])
        if self.folder == folder, pageMessage == nil { password = "" }
    }
    func syncNow() async { if let folder { await perform("imap_sync", folder: folder) } }
    func disconnect() async {
        guard let folder else { return }
        await perform("imap_disable", folder: folder)
        if self.folder == folder, pageMessage == nil { editing = false; prefill(from: status) }
    }
    func beginChange() { editing = true; prefill(from: status) }
    func cancelChange() { editing = false; password = ""; pageMessage = nil }

    private func perform(_ command: String, folder: URL, _ fields: [(String, JSONValue)] = []) async {
        guard !busy else { return }
        activity = .working; defer { activity = nil }
        pageMessage = nil
        do {
            let r = try await client.command(command, binder: folder, fields, timeout: command == "imap_disable" ? 20 : 10)
            if self.folder == folder { status = Self.status(r) }
        } catch {
            if self.folder == folder { pageMessage = (error as? RuntimeClient.Failure)?.message ?? "Sprava could not reach its background part." }
        }
    }

    private func refresh(prefill: Bool) async {
        guard let folder else { return }
        do {
            let r = try await client.command("imap_status", binder: folder, timeout: 5)
            guard self.folder == folder else { return }
            status = Self.status(r)
            if prefill, !editing { self.prefill(from: status) }
        } catch {
            if self.folder == folder { pageMessage = (error as? RuntimeClient.Failure)?.message ?? "Sprava could not check email intake." }
        }
    }

    /// Puts a saved connection's answers back in the form. The server counts as checked with what it had then, and a
    /// pinned certificate as trusted; signing in again shows the folders.
    private func prefill(from status: Status) {
        guard let host = status.host, let security = status.security, let port = status.port else { return }
        loading = true; defer { loading = false }
        self.host = host; self.security = security; self.port = String(port); user = status.user ?? ""
        server = ServerCheck(host: host, security: security, port: port, result: status.pin == nil ? "ok" : "untrusted",
                             fingerprint: status.pin, loopback: status.pin != nil, attempts: [])
        trusted = status.pin != nil
        folders = nil; mailbox = status.mailbox; includeExisting = status.includeExisting
        sender = status.sender; subject = status.subject; search = status.search
        serverMessage = nil; accountMessage = nil; connectMessage = nil
    }

    private func serverChanged() {
        guard !loading else { return }
        server = nil; trusted = false; folders = nil; serverMessage = nil; accountMessage = nil
    }

    private func reset() {
        loading = true; defer { loading = false }
        host = ""; security = .tls; port = "993"; server = nil; trusted = false; serverMessage = nil
        user = ""; password = ""; folders = nil; accountMessage = nil
        mailbox = nil; filter = ""; includeExisting = true; sender = ""; subject = ""; search = ""; connectMessage = nil
        status = Status(); editing = false; pageMessage = nil; chosenByHand = false
    }

    private func accountFields() -> [(String, JSONValue)] {
        var fields: [(String, JSONValue)] = [("host", .str(normalizedHost)), ("port", .int(Int(port) ?? 0)),
                                             ("security", .str(security.rawValue)), ("user", .str(user))]
        if trusted, let pin = server?.fingerprint { fields.append(("pin", .str(pin))) }
        return fields
    }
}
