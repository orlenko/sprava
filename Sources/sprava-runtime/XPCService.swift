import Foundation
import BinderStore
import Services
import SpravaKit

/// The runtime's XPC listener: the only door through which the app changes a binder (architecture 2.1).
/// Every request runs on one serial queue, so the runtime is the single writer.
final class XPCService: NSObject, NSXPCListenerDelegate, SpravaRuntimeXPC, @unchecked Sendable {
    let commands: Commands
    let queue = DispatchQueue(label: "sprava.runtime.commands")
    let log: @Sendable (String) -> Void
    var listener: NSXPCListener?

    init(commands: Commands, log: @escaping @Sendable (String) -> Void) {
        self.commands = commands
        self.log = log
    }

    func start() {
        let listener = NSXPCListener(machServiceName: XPCNames.runtime)
        listener.setConnectionCodeSigningRequirement(XPCNames.appRequirement)
        listener.delegate = self
        listener.resume()
        self.listener = listener
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SpravaRuntimeXPC.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func handle(_ request: String, reply: @escaping (String) -> Void) {
        let commands = self.commands
        let log = self.log
        queue.async {
            let started = Date()
            let answer = commands.handle(request)
            // Names, counts and codes only (architecture 3.7).
            let command = (try? JSONParser.parse(request).value["command"]?.stringValue) ?? "?"
            let ok = (try? JSONParser.parse(answer).value["ok"]) == .bool(true)
            log("job=app_request command=\(command ?? "?") ok=\(ok) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            reply(answer)
        }
    }
}
