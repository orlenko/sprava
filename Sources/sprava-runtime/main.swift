import Darwin
import Foundation
import SpravaCore

// sprava-runtime: the background process (architecture section 3), and with --watch the outside watcher
// (architecture 3.3). launchd starts both from the app bundle. --dev uses a separate state folder, so a
// development run never meets the installed app's data.

var args = Array(CommandLine.arguments.dropFirst())
let dev = args.contains("--dev")
args.removeAll { $0 == "--dev" }

var support = SpravaPaths.supportDirectory()
if dev { support = support.deletingLastPathComponent().appendingPathComponent(support.lastPathComponent + "-dev") }
let runtimeDir = support.appendingPathComponent("runtime", isDirectory: true)

do {
    try AtomicFile.makePrivateFolder(runtimeDir)
} catch {
    FileHandle.standardError.write(Data("cannot create \(runtimeDir.path): \(error)\n".utf8))
    exit(1)
}

if args.first == "--watch" {
    exit(OutsideWatcher(runtimeDir: runtimeDir).runOnce())
}

// The weekly fault drill, part two (mvp.md 1.2, M3 part 4): a hidden developer setting makes the runtime exit at
// start, before its lease, so launchd keeps restarting it and the heartbeat goes stale.
if let data = try? Data(contentsOf: support.appendingPathComponent("developer.json")),
   (try? JSONParser.parse(data).value)?["drill_exit_at_start"] == .bool(true) {
    AtomicFile.appendLine("\(ISOTime.string(Date())) drill exit_at_start", to: runtimeDir.appendingPathComponent("jobs.log"))
    exit(75)
}

switch try Lease.acquire(at: runtimeDir.appendingPathComponent("lease")) {
case .held(let pid):
    // Another runtime holds the lease (an old copy still exiting after an update, or a copy started by hand).
    // Record it and exit 0; launchd retries after its 10-second throttle (architecture 3.2).
    AtomicFile.appendLine("\(ISOTime.string(Date())) lease held by pid \(pid.map(String.init) ?? "?")",
                          to: runtimeDir.appendingPathComponent("lease-refusals.log"))
    RuntimeState.recordRefusal(runtimeDir)
    exit(0)
case .acquired(let lease):
    let runtime = Runtime(support: support, lease: lease)
    runtime.start()
    dispatchMain()
}
