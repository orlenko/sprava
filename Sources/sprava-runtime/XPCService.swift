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
    /// The command queue, which the MCP listener and the jobs that write cards share.
    var queue: DispatchQueue { queues.commands }
    let log: @Sendable (String) -> Void
    var listener: NSXPCListener?

    init(commands: Commands, watch: WatchBox?, log: @escaping @Sendable (String) -> Void) {
        self.commands = commands
        queues = RequestQueues(watch: watch)
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
        queues.submit(request, handle: { commands.handle($0) }) { answer, command, ms in
            // Names, counts and codes only (architecture 3.7).
            let ok = (try? JSONParser.parse(answer).value["ok"]) == .bool(true)
            log("job=app_request command=\(command) ok=\(ok) ms=\(ms)")
            reply(answer)
        }
    }
}
