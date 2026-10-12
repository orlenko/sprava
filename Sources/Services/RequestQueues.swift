import Foundation
import SpravaKit

/// Where an app request runs (architecture 2.1, 3.4). Binder commands run one at a time on the command queue, the
/// single writer, which the MCP listener and the capture and intake jobs share. Backup repository work (restic:
/// peek, setup, the second copy) runs on a serial queue of its own, so a slow or stalled cloud folder never holds up
/// approvals, MCP calls or captures; it touches no binder. Each request is registered with the watchdog while it
/// runs, so one that hangs is named, and past twice its budget and ten minutes ends the process for launchd to restart.
public final class RequestQueues: @unchecked Sendable {
    public static let repositoryCommands: Set<String> = ["peek", "backup_setup", "backup_second"]
    /// The watchdog's keys and budgets: the app's longest timeout for each kind (15 seconds for a write; ten minutes
    /// for a peek).
    public static let budgets: [String: Duration] = ["app_request": .seconds(15), "app_backup_request": .seconds(600)]

    public let commands = DispatchQueue(label: "sprava.runtime.commands")
    public let repository = DispatchQueue(label: "sprava.runtime.backup-requests")
    let watch: WatchBox?

    public init(watch: WatchBox?) { self.watch = watch }

    /// The request's command name, or "?".
    public static func command(of request: String) -> String {
        (try? JSONParser.parse(request).value["command"]?.stringValue) ?? "?"
    }

    /// Runs `handle` on the request's queue and passes its answer to `reply`, with the command's name and how long it
    /// took in milliseconds.
    public func submit(_ request: String, handle: @escaping @Sendable (String) -> String,
                       reply: @escaping @Sendable (_ answer: String, _ command: String, _ ms: Int) -> Void) {
        let command = Self.command(of: request)
        let repositoryWork = Self.repositoryCommands.contains(command)
        let key = repositoryWork ? "app_backup_request" : "app_request"
        let watch = self.watch
        (repositoryWork ? repository : commands).async {
            let started = ContinuousClock.now   // elapsed time, whatever the wall clock does meanwhile
            watch?.started(key)
            let answer = handle(request)
            watch?.finished(key)
            let elapsed = started.duration(to: ContinuousClock.now).components
            reply(answer, command, Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000))
        }
    }
}

