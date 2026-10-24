import Backup
import BinderFormat
import Capture
import Foundation
import Extract
import Shelf
import SpravaKit

/// The signed app's built-in IMAP plugin controls. Configuration is external trusted state, never
/// binder instructions. Timers reuse this owner; model/MCP requests cannot reach its command door.
public actor BinderIMAPRuntime {
    public static let commands: Set<String> = ["imap_status", "imap_configure", "imap_disable", "imap_sync"]
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func stop() { lock.lock(); value = true; lock.unlock() }
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private let support: URL
    private let connections: BinderIMAPConnections
    private let fetch: IMAPIntakeImport.Fetch?
    private let reader: ExtractHelper.Reader
    private let available: @Sendable (URL) throws -> Bool
    private var running: (id: UUID, cancellation: Cancellation, task: Task<Int, Error>)?
    private var messages: [UUID: String] = [:]
    private var next = Date.distantPast
    private var offset = 0
    private var changing = false
    public init(support: URL) throws {
        self.support = support; connections = try BinderIMAPConnections(support: support); fetch = nil; reader = .located()
        available = { folder in
            let shelf = ShelfStore(supportDirectory: support)
            let folders = try shelf.readFolders() + (shelf.registryForShelf()?.entries.filter { !$0.archived }.compactMap(\.workingDir).map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            } ?? [])
            let listed = folders.contains { $0.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() }
            let offloading = try BackupRequests(support: support).all().contains {
                $0.binder == folder.path && $0.kind == "offload" && ["queued", "running", "waiting_for_icloud"].contains($0.state)
            }
            return listed && !offloading
        }
    }
    init(support: URL, connections: BinderIMAPConnections, fetch: @escaping IMAPIntakeImport.Fetch,
         available: @escaping @Sendable (URL) throws -> Bool = { _ in true }, reader: ExtractHelper.Reader = .inProcess) {
        self.support = support; self.connections = connections; self.fetch = fetch; self.available = available; self.reader = reader
    }
    public func respond(_ text: String) async -> String {
        do {
            let parsed = try JSONParser.parse(text)
            guard text.utf8.count <= 16 * 1024, parsed.safety.isSafe, let r = parsed.value.objectValue,
                  let command = r["command"]?.stringValue, Self.commands.contains(command),
                  let path = r["binder"]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else { throw IMAPIntakeImport.Refused.unavailable }
            guard !changing || command == "imap_status" else { throw IMAPIntakeImport.Refused.unavailable }
            let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if command == "imap_configure" {
                guard running == nil, try available(folder), let env = r["environment"]?.stringValue, env.hasPrefix("/"),
                      let mailbox = r["mailbox"]?.stringValue else { throw IMAPIntakeImport.Refused.unavailable }
                let value = try connections.configure(folder: folder, environment: URL(fileURLWithPath: env), mailbox: mailbox,
                    sender: r["sender"]?.stringValue ?? "", subject: r["subject"]?.stringValue ?? "", search: r["search"]?.stringValue ?? "",
                    port: r["starttls"] == .bool(true) ? 143 : 993, startTLS: r["starttls"] == .bool(true),
                    includeExisting: r["include_existing"] != .bool(false))
                start(value)
            } else if command == "imap_disable" { try await retire(folder) }
            else if command == "imap_sync" {
                guard running == nil, let value = try connections.configuration(for: folder), value.enabled, try available(folder) else { throw IMAPIntakeImport.Refused.unavailable }
                start(value)
            }
            let value = try connections.configuration(for: folder)
            let installed = (try? IMAPNativeFetch.installedProgram()) != nil
            var fields: [(String, JSONValue)] = [("ok", .bool(true)), ("installed", .bool(installed)), ("enabled", .bool(value?.enabled == true)),
                ("running", .bool(value.map { running?.id == $0.id } ?? false)),
                ("message", .str(value.flatMap { messages[$0.id] } ?? "Choose the private IMAP .env file and a server mailbox or label to connect this binder."))]
            if let value {
                fields += [("mailbox", .str(value.mailbox)), ("sender", .str(value.sender)), ("subject", .str(value.subject)), ("search", .str(value.search)),
                           ("starttls", .bool(value.startTLS)), ("include_existing", .bool(value.includeExisting))]
            }
            return JSONWriter.compact(.obj(fields))
        } catch {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str("IMAP could not complete this request. Check the background connection, installed Python 3, private .env permissions, and selected mailbox. No email was sent or marked read."))]))
        }
    }
    public func routeAppRequest(_ text: String, perform: @escaping @Sendable (String) async -> String) async -> String {
        guard let value = try? JSONParser.parse(text).value, let command = value["command"]?.stringValue else { return await perform(text) }
        if Self.commands.contains(command) { return await respond(text) }
        let retires = ["shelf_remove", "expunge", "transfer"].contains(command) ||
            (command == "backup_request" && value["kind"] == .str("offload"))
        guard retires else { return await perform(text) }
        guard !changing, let path = value["binder"]?.stringValue, path.hasPrefix("/") else {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str("IMAP could not stop safely before this binder change."))]))
        }
        changing = true; defer { changing = false }
        do { try await retire(URL(fileURLWithPath: path)); return await perform(text) }
        catch { return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str("IMAP could not stop safely before this binder change. Nothing was confirmed."))])) }
    }
    public func tick(now: Date = Date()) {
        guard running == nil, !changing, now >= next else { return }
        next = now.addingTimeInterval(300)
        guard let values = try? connections.enabled(), !values.isEmpty else { return }
        for i in values.indices {
            let index = (offset + i) % values.count, value = values[index]
            if (try? available(value.folder)) == true {
                offset = (index + 1) % values.count; start(value); return
            }
        }
    }
    /// Called before a signed-app removal/offload is submitted. Disable first, then await confirmed
    /// fetch completion; publication rechecks this external grant before touching intake.
    public func retire(_ folder: URL) async throws {
        let value = try connections.configuration(for: folder)
        try connections.disable(folder: folder)
        if let value, let current = running, current.id == value.id {
            current.cancellation.stop(); _ = try? await current.task.value
        }
    }
    private func start(_ value: BinderIMAPConnections.Configuration) {
        let cancellation = Cancellation(), support = self.support, connections = self.connections, available = self.available, supplied = fetch, reader = self.reader
        messages[value.id] = "Synchronizing privately…"
        let task = Task.detached(priority: .utility) {
            let fetch: IMAPIntakeImport.Fetch = { config, cwd, target in
                guard !cancellation.stopped, try available(config.folder) else { throw IMAPIntakeImport.Refused.unavailable }
                if let supplied { try supplied(config, cwd, target) }
                else { try IMAPNativeFetch.run(config, directory: cwd, messages: target, cancelled: { cancellation.stopped }) }
            }
            let first = try IMAPIntakeImport.run(value, support: support, connections: connections, fetch: fetch, reader: reader, canPublish: { guard !cancellation.stopped else { return false }; return try available(value.folder) })
            guard !cancellation.stopped, try available(value.folder) else { throw IMAPIntakeImport.Refused.unavailable }
            // First-run Include existing needs a baseline followed by a fetch; at most two calls.
            let second = try IMAPIntakeImport.run(value, support: support, connections: connections, fetch: fetch, reader: reader, canPublish: { guard !cancellation.stopped else { return false }; return try available(value.folder) })
            return first + second
        }
        running = (value.id, cancellation, task)
        Task {
            do { let count = try await task.value; messages[value.id] = "Check complete: \(count) new matching message(s). Next automatic check is within five minutes. Server messages stay unchanged." }
            catch IMAPIntakeImport.Refused.authentication {
                try? connections.disable(folder: value.folder)
                messages[value.id] = "The IMAP server refused this login. Automatic checks are disabled. Correct the private .env account/password, then select it and Enable again."
            }
            catch IMAPIntakeImport.Refused.partial(let count) { messages[value.id] = "Imported \(count) complete message(s) before this check stopped. Sync now or wait for the next automatic check to continue; partial messages were not published." }
            catch { messages[value.id] = "Sync paused. Check the server, TLS certificate, private .env permissions or changed credentials; reconnect after correcting them. Completed intake files remain. No server message was changed." }
            if running?.id == value.id { running = nil }
        }
    }
}
