import Backup
import BinderFormat
import Capture
import Clerk
import Foundation
import Extract
import Shelf
import SpravaKit

/// The signed app's built-in email intake controls. Configuration is external trusted state, never
/// binder instructions. Timers reuse this owner; model/MCP requests cannot reach its command door.
public actor BinderIMAPRuntime {
    public static let commands: Set<String> = ["imap_status", "imap_probe", "imap_folders", "imap_configure", "imap_password", "imap_disable", "imap_sync",
                                               "imap_drafts", "imap_draft_retry", "imap_draft_discard"]
    /// The setup checks, replaceable in tests so no test reaches a server.
    public struct Checks: Sendable {
        let probe: @Sendable (IMAPAccount) throws -> IMAPServerCheck.Answer
        let folders: @Sendable (IMAPAccount, String) throws -> [String]
        public init(probe: @escaping @Sendable (IMAPAccount) throws -> IMAPServerCheck.Answer,
                    folders: @escaping @Sendable (IMAPAccount, String) throws -> [String]) { self.probe = probe; self.folders = folders }
        static func native(_ support: URL) -> Checks {
            Checks(probe: { try IMAPServerCheck.probe($0, support: support) },
                   folders: { try IMAPServerCheck.folders($0, password: $1, support: support) })
        }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func stop() { lock.lock(); value = true; lock.unlock() }
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private struct Refusal: Error { let message: String }
    private let support: URL
    private let connections: BinderIMAPConnections
    private let passwords: IMAPPasswords
    private let checks: Checks
    private let fetch: IMAPIntakeImport.Fetch?
    private let place: DraftPlacing.Place
    /// The draft being placed now, if any (integrations.md §5.2).
    private var placing: Task<DraftPlacing.Outcome, Never>?
    private let log: @Sendable (String) -> Void
    private let reader: ExtractHelper.Reader
    private let available: @Sendable (URL) throws -> Bool
    private var running: (id: UUID, cancellation: Cancellation, task: Task<Int, Error>)?
    private var messages: [UUID: String] = [:]
    private var next = Date.distantPast
    private var offset = 0
    private var changing = false
    public init(support: URL, log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.support = support; connections = try BinderIMAPConnections(support: support); fetch = nil; reader = .located()
        place = DraftPlacing.native; self.log = log
        passwords = IMAPPasswords(); checks = .native(support)
        available = { try ListedBinder.accepts($0, support: support) }
    }
    init(support: URL, connections: BinderIMAPConnections, passwords: IMAPPasswords, checks: Checks? = nil, fetch: @escaping IMAPIntakeImport.Fetch,
         available: @escaping @Sendable (URL) throws -> Bool = { _ in true }, reader: ExtractHelper.Reader = .inProcess,
         place: @escaping DraftPlacing.Place = { _, _, _, _ in throw IMAPIntakeImport.Refused.unavailable }, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.support = support; self.connections = connections; self.passwords = passwords; self.fetch = fetch; self.available = available; self.reader = reader
        self.place = place; self.log = log
        self.checks = checks ?? Checks(probe: { _ in throw IMAPIntakeImport.Refused.unavailable }, folders: { _, _ in throw IMAPIntakeImport.Refused.unavailable })
    }
    public func respond(_ text: String) async -> String {
        do {
            let parsed = try JSONParser.parse(text)
            guard text.utf8.count <= 16 * 1024, parsed.safety.isSafe, let r = parsed.value.objectValue,
                  let command = r["command"]?.stringValue, Self.commands.contains(command),
                  let path = r["binder"]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else { throw IMAPIntakeImport.Refused.unavailable }
            guard !changing || command == "imap_status" else { throw IMAPIntakeImport.Refused.unavailable }
            let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            switch command {
            case "imap_probe": return try await probe(r, folder: folder)
            case "imap_folders": return try await folders(r, folder: folder)
            case "imap_configure":
                guard running == nil, try available(folder), let account = Self.account(r), !account.user.isEmpty,
                      let mailbox = r["mailbox"]?.stringValue else { throw IMAPIntakeImport.Refused.unavailable }
                // The person's other addresses, so mail they wrote proposes no to-dos (issue #594).
                let listed = r["own_addresses"].map { $0.arrayValue ?? [.null] } ?? []
                let own = listed.compactMap(\.stringValue)
                guard own.count == listed.count, own.allSatisfy({ MailAddress.single($0) != nil }) else {
                    throw Refusal(message: "Write each of your other addresses in full, such as name@example.com, separated by commas.")
                }
                guard Set(own.compactMap(MailAddress.single)).count <= BinderIMAPConnections.maxOwnAddresses else {
                    throw Refusal(message: "Give at most \(BinderIMAPConnections.maxOwnAddresses) other addresses.")
                }
                if let password = r["password"]?.stringValue { try passwords.store(password, for: account) }
                guard try passwords.read(account) != nil else { throw Refusal(message: "Enter the account's password, then connect again.") }
                let value = try connections.configure(folder: folder, account: account, mailbox: mailbox,
                    sender: r["sender"]?.stringValue ?? "", subject: r["subject"]?.stringValue ?? "", search: r["search"]?.stringValue ?? "",
                    includeExisting: r["include_existing"] != .bool(false), ownAddresses: own)
                start(value)
            case "imap_password":
                guard let value = try connections.configuration(for: folder), value.enabled, try available(folder),
                      let password = r["password"]?.stringValue else { throw IMAPIntakeImport.Refused.unavailable }
                try passwords.store(password, for: value.account)
                if running == nil { start(value) }
            case "imap_disable":
                let account = try connections.configuration(for: folder)?.account
                try await retire(folder)
                if let account, try !connections.enabled().contains(where: { $0.account.sharesPassword(with: account) }) { passwords.remove(account) }
            case "imap_drafts":
                return try drafts(folder)
            case "imap_draft_retry", "imap_draft_discard":
                // Only a draft of this binder, by its card id.
                let requests = DraftRequests(support: support)
                guard let id = r["id"]?.stringValue, let request = requests.all().first(where: { $0.id == id }),
                      URL(fileURLWithPath: request.binder).resolvingSymlinksInPath() == folder else { throw IMAPIntakeImport.Refused.unavailable }
                if command == "imap_draft_retry" { if request.state == .failed { try requests.ready(id: id) } }
                else { guard placing == nil else { throw Refusal(message: "A draft is being placed now; try again in a moment.") }; try requests.remove(id: id) }
                return try drafts(folder)
            case "imap_sync":
                guard running == nil, let value = try connections.configuration(for: folder), value.enabled, try available(folder) else { throw IMAPIntakeImport.Refused.unavailable }
                start(value)
            default: break
            }
            return try status(folder)
        } catch let refusal as Refusal {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str(refusal.message))]))
        } catch {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str("Email intake could not complete this request. Check the background connection and that Python 3 is installed. No email was sent or marked read."))]))
        }
    }
    private func status(_ folder: URL) throws -> String {
        let value = try connections.configuration(for: folder)
        let installed = (try? IMAPNativeFetch.installedProgram()) != nil
        let needsPassword = value.map { $0.enabled && (try? passwords.read($0.account)) == nil } ?? false
        var fields: [(String, JSONValue)] = [("ok", .bool(true)), ("installed", .bool(installed)), ("enabled", .bool(value?.enabled == true)),
            ("running", .bool(value.map { running?.id == $0.id } ?? false)), ("needs_password", .bool(needsPassword))]
        if let value {
            if let message = messages[value.id] { fields.append(("message", .str(message))) }
            fields += [("host", .str(value.account.host)), ("port", .int(value.account.port)), ("security", .str(value.account.security.rawValue)),
                       ("pin", value.account.pin.map { .str($0) } ?? .null), ("user", .str(value.account.user)),
                       ("mailbox", .str(value.mailbox)), ("sender", .str(value.sender)), ("subject", .str(value.subject)), ("search", .str(value.search)),
                       ("include_existing", .bool(value.includeExisting)), ("own_addresses", .array(value.ownAddresses.map { .str($0) }))]
        }
        return JSONWriter.compact(.obj(fields))
    }
    /// Tries the named port and security, or the likely ones for the host in order, and stops at the first that answers.
    private func probe(_ r: JSONObject, folder: URL) async throws -> String {
        guard try available(folder), let host = r["host"]?.stringValue else { throw IMAPIntakeImport.Refused.unavailable }
        var candidates = IMAPAccount.candidates(host: host)
        if let security = r["security"]?.stringValue.flatMap(IMAPAccount.Security.init(rawValue:)), let port = Self.integer(r["port"]) { candidates = [(security, port)] }
        var attempts: [JSONValue] = []
        var chosen: (account: IMAPAccount, answer: IMAPServerCheck.Answer)?
        for (security, port) in candidates {
            guard let account = IMAPAccount(host: host, port: port, security: security) else {
                throw Refusal(message: "Enter a server name such as imap.example.com, or 127.0.0.1 for a bridge on this Mac.")
            }
            let checks = self.checks
            let answer = try await Task.detached(priority: .userInitiated) { try checks.probe(account) }.value
            attempts.append(.obj([("security", .str(security.rawValue)), ("port", .int(port)), ("result", .str(answer.result.rawValue))]))
            if chosen == nil { chosen = (account, answer) }
            if [.ok, .oauthOnly, .untrusted].contains(answer.result) { chosen = (account, answer); break }
            if answer.result == .unknownHost { break }
        }
        guard let chosen else { throw IMAPIntakeImport.Refused.unavailable }
        return JSONWriter.compact(.obj([("ok", .bool(true)), ("result", .str(chosen.answer.result.rawValue)),
            ("host", .str(chosen.account.host)), ("security", .str(chosen.account.security.rawValue)), ("port", .int(chosen.account.port)),
            ("fingerprint", chosen.answer.fingerprint.map { .str($0) } ?? .null), ("loopback", .bool(chosen.account.isLoopback)),
            ("attempts", .array(attempts))]))
    }
    /// Signs in and lists the folders. The password typed in setup, or the one already kept for this account.
    private func folders(_ r: JSONObject, folder: URL) async throws -> String {
        guard try available(folder), let account = Self.account(r), !account.user.isEmpty else { throw IMAPIntakeImport.Refused.unavailable }
        guard let password = try r["password"]?.stringValue ?? passwords.read(account), !password.isEmpty else {
            throw Refusal(message: "Enter the account's password.")
        }
        let checks = self.checks
        do {
            let names = try await Task.detached(priority: .userInitiated) { try checks.folders(account, password) }.value
            return JSONWriter.compact(.obj([("ok", .bool(true)), ("folders", .array(names.map { .str($0) }))]))
        } catch IMAPIntakeImport.Refused.authentication {
            throw Refusal(message: account.isLoopback
                ? "The bridge refused this username or password. Use the password the bridge shows for this account, not your mail account's own password."
                : "The server refused this username or password. If the account uses two-step sign-in, create an app password for it.")
        } catch IMAPIntakeImport.Refused.untrusted {
            throw Refusal(message: "The bridge now offers a different certificate. Check the server again and trust its current certificate only if you expected the change.")
        } catch {
            throw Refusal(message: "Sprava signed in to no folder list: the server stopped answering or sent something unexpected. Check the server again.")
        }
    }
    static func account(_ r: JSONObject) -> IMAPAccount? {
        guard let host = r["host"]?.stringValue, let port = integer(r["port"]),
              let security = r["security"]?.stringValue.flatMap(IMAPAccount.Security.init(rawValue:)) else { return nil }
        return IMAPAccount(host: host, port: port, security: security, pin: r["pin"]?.stringValue, user: r["user"]?.stringValue ?? "")
    }
    static func integer(_ value: JSONValue?) -> Int? {
        guard let number = value?.numberValue, number.isIntegerLiteral else { return nil }
        return Int(number.text)
    }
    public func routeAppRequest(_ text: String, perform: @escaping @Sendable (String) async -> String) async -> String {
        guard let value = try? JSONParser.parse(text).value, let command = value["command"]?.stringValue else { return await perform(text) }
        if Self.commands.contains(command) { return await respond(text) }
        let retires = ["shelf_remove", "expunge", "transfer"].contains(command) ||
            (command == "backup_request" && value["kind"] == .str("offload"))
        guard retires else { return await perform(text) }
        guard !changing, let path = value["binder"]?.stringValue, path.hasPrefix("/") else {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str("Email intake could not stop safely before this binder change."))]))
        }
        changing = true; defer { changing = false }
        do { try await retire(URL(fileURLWithPath: path)); return await perform(text) }
        catch { return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str("Email intake could not stop safely before this binder change. Nothing was confirmed."))])) }
    }
    public func tick(now: Date = Date()) {
        placeDrafts(now: now)
        guard running == nil, !changing, now >= next else { return }
        next = now.addingTimeInterval(300)
        // A connection whose password this runtime does not have waits for the person; it never tries the server.
        guard let values = try? connections.enabled().filter({ (try? passwords.read($0.account)) != nil }), !values.isEmpty else { return }
        for i in values.indices {
            let index = (offset + i) % values.count, value = values[index]
            if (try? available(value.folder)) == true {
                offset = (index + 1) % values.count; start(value); return
            }
        }
    }
    /// Starts placing the next approved draft unless one is under way (integrations.md §5.2).
    private func placeDrafts(now: Date) {
        guard placing == nil, !changing else { return }
        let support = self.support, connections = self.connections, passwords = self.passwords, available = self.available, place = self.place
        let task = Task.detached(priority: .utility) {
            DraftPlacing.run(support: support, connections: connections, password: { try passwords.read($0) }, available: available, place: place, now: now)
        }
        placing = task
        Task {
            let outcome = await task.value
            if outcome != .none && outcome != .waiting { log("imap draft outcome=\(outcome.rawValue)") }
            placing = nil
        }
    }

    /// The approved drafts of one binder that are not placed yet, in fixed words.
    private func drafts(_ folder: URL) throws -> String {
        let mine = DraftRequests(support: support).all().filter { URL(fileURLWithPath: $0.binder).resolvingSymlinksInPath() == folder }
        let rows: [JSONValue] = mine.map { r in
            .obj([("id", .str(r.id)), ("state", .str(r.state.rawValue)), ("failure", r.failure.map(JSONValue.str) ?? .null)])
        }
        return JSONWriter.compact(.obj([("ok", .bool(true)), ("drafts", .array(rows))]))
    }

    /// Called before a signed-app removal/offload is submitted. Disable first, then await confirmed
    /// fetch completion; publication rechecks this external grant before touching intake.
    public func retire(_ folder: URL) async throws {
        // Its approved drafts not placed yet go nowhere while it is away: the person tries them again when it is back.
        let requests = DraftRequests(support: support)
        for request in requests.all() where URL(fileURLWithPath: request.binder).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() {
            if request.state == .ready { try? requests.failed(id: request.id, reason: "binder put away") }
        }
        let value = try connections.configuration(for: folder)
        try connections.disable(folder: folder)
        if let value, let current = running, current.id == value.id {
            current.cancellation.stop(); _ = try? await current.task.value
        }
    }
    private func start(_ value: BinderIMAPConnections.Configuration) {
        let cancellation = Cancellation(), support = self.support, connections = self.connections, available = self.available, supplied = fetch, reader = self.reader
        let passwords = self.passwords
        messages[value.id] = "Checking for new mail…"
        let task = Task.detached(priority: .utility) {
            let fetch: IMAPIntakeImport.Fetch = { config, cwd, target in
                guard !cancellation.stopped, try available(config.folder) else { throw IMAPIntakeImport.Refused.unavailable }
                guard let password = try passwords.read(config.account) else { throw IMAPIntakeImport.Refused.needsPassword }
                if let supplied { try supplied(config, cwd, target) }
                else { try IMAPNativeFetch.run(config, password: password, directory: cwd, messages: target, cancelled: { cancellation.stopped }) }
            }
            let first = try IMAPIntakeImport.run(value, support: support, connections: connections, fetch: fetch, reader: reader, canPublish: { guard !cancellation.stopped else { return false }; return try available(value.folder) })
            guard !cancellation.stopped, try available(value.folder) else { throw IMAPIntakeImport.Refused.unavailable }
            // First-run Include existing needs a baseline followed by a fetch; at most two calls.
            let second = try IMAPIntakeImport.run(value, support: support, connections: connections, fetch: fetch, reader: reader, canPublish: { guard !cancellation.stopped else { return false }; return try available(value.folder) })
            return first + second
        }
        running = (value.id, cancellation, task)
        Task {
            do {
                let count = try await task.value
                messages[value.id] = "Checked at \(Date().formatted(date: .omitted, time: .shortened)): \(count == 0 ? "no new mail" : count == 1 ? "1 new message" : "\(count) new messages"). Next check within five minutes."
            }
            catch IMAPIntakeImport.Refused.authentication {
                try? connections.disable(folder: value.folder)
                messages[value.id] = "The server refused the saved sign-in, so automatic checks stopped. Choose Change… and sign in again."
            }
            catch IMAPIntakeImport.Refused.untrusted {
                try? connections.disable(folder: value.folder)
                messages[value.id] = "The bridge on this Mac offered a different certificate than the one you trusted, so automatic checks stopped. Choose Change… and check the server again."
            }
            catch IMAPIntakeImport.Refused.needsPassword { messages[value.id] = nil }
            catch IMAPIntakeImport.Refused.partial(let count) { messages[value.id] = "Imported \(count) complete message(s) before this check stopped. The rest come with the next check; no partial message was saved." }
            catch { messages[value.id] = "The last check did not finish: the server did not answer, or a limit was reached. Sprava tries again within five minutes. Mail already imported stays." }
            if running?.id == value.id { running = nil }
        }
    }
}
