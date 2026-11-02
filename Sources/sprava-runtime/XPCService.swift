import Foundation
import BinderStore
import Services
import SpravaKit

/// The runtime's XPC listener: the only door through which the app changes a binder (architecture 2.1).
/// Binder commands run on one serial queue, so the runtime is the single writer; backup repository work runs on a
/// queue of its own (`RequestQueues`).
final class XPCService: NSObject, NSXPCListenerDelegate, SpravaRuntimeXPC, @unchecked Sendable {
    let commands: Commands
    let queues: RequestQueues
    /// The same session is available to future companion jobs; never construct another owner per request.
    let companion: CompanionRuntimeRequests?
    let claude: ClaudeConversationRuntime?
    let imap: BinderIMAPRuntime?
    /// The command queue, which the MCP listener and the jobs that write cards share.
    var queue: DispatchQueue { queues.commands }
    let log: @Sendable (String) -> Void
    var listener: NSXPCListener?

    init(commands: Commands, watch: WatchBox?, companion: CompanionRuntimeRequests?, claude: ClaudeConversationRuntime? = nil, imap: BinderIMAPRuntime? = nil, log: @escaping @Sendable (String) -> Void) {
        self.commands = commands
        queues = RequestQueues(watch: watch)
        self.companion = companion
        self.claude = claude
        self.imap = imap
        self.log = log
    }

    func start() {
        let listener = NSXPCListener(machServiceName: XPCNames.runtime)
        listener.delegate = self
        listener.resume()
        self.listener = listener
    }

    /// Only the app in this runtime's own bundle (`XPCPeer`). Its signature is read for each connection, so an app
    /// updated together with the bundle is admitted; one that cannot be read admits nobody.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let app: XPCPeer.App
        do {
            app = try XPCPeer.app(at: Bundle.main.bundleURL)
        } catch {
            log("xpc refused reason=app_unverifiable")
            return false
        }
        guard XPCPeer.accepts(peerUID: connection.effectiveUserIdentifier, peerPath: XPCPeer.path(of: connection.processIdentifier), app: app) else {
            log("xpc refused reason=not_the_app")
            return false
        }
        // Checked by the system on every message, against the peer's audit token.
        connection.setCodeSigningRequirement(XPCPeer.requirement(for: app))
        connection.exportedInterface = NSXPCInterface(with: SpravaRuntimeXPC.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func handle(_ request: String, reply: @escaping (String) -> Void) {
        let commands = self.commands
        let log = self.log
        nonisolated(unsafe) let reply = reply
        let queues = self.queues, companion = self.companion, claude = self.claude, imap = self.imap
        Task {
            if let refusal = commands.generalRetirementRefusal(request) { reply(refusal); return }
            let write: @Sendable (String) async -> String = { body in
                await withCheckedContinuation { continuation in
                    queues.submit(body, handle: { commands.handle($0) }, companion: companion?.requests) { answer, command, ms in
                        let ok = (try? JSONParser.parse(answer).value["ok"]) == .bool(true)
                        log("job=app_request command=\(command) ok=\(ok) ms=\(ms)")
                        continuation.resume(returning: answer)
                    }
                }
            }
            // Both owners fence lifecycle changes before the existing single writer acknowledges
            // them. Model/MCP/CLI traffic never reaches this app-authenticated configuration door.
            let conversation: @Sendable (String) async -> String = { body in
                if let claude { return await claude.routeAppRequest(body, perform: write) }
                return await write(body)
            }
            let answer: String
            if let imap { answer = await imap.routeAppRequest(request, perform: conversation) }
            else { answer = await conversation(request) }
            reply(answer)
        }
    }

    /// A dropped file (conversation.md 5.1): copied on the command queue, so it is serialized with every binder change.
    func importFile(_ request: String, file: FileHandle, reply: @escaping (String) -> Void) {
        let commands = self.commands, log = self.log, support = commands.support
        nonisolated(unsafe) let reply = reply
        queue.async {
            let started = ContinuousClock.now
            let answer = commands.dropIntake(request, file: file, listed: { try ListedBinder.accepts($0, support: support) })
            try? file.close()
            let ok = (try? JSONParser.parse(answer).value["ok"]) == .bool(true)
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            log("job=app_request command=intake_drop ok=\(ok) ms=\(ms)")
            reply(answer)
        }
    }
}
