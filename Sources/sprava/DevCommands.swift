import BinderFormat
import BinderStore
import Brains
import Capture
import Foundation
import Hub
import Services
import SpravaKit

/// Development commands: the same `Commands` the runtime runs for the app, in-process, with the development
/// identity and state (`DevelopmentSupport.directory`, shared with `sprava-runtime --dev`). Never on a folder
/// lifeproj's registry lists, the installed app's Shelf holds or the installed app owns, so a live binder is only
/// ever written by the installed runtime.
func dev(_ args: [String]) {
    guard args.count >= 2 else { fail(usage) }
    let folder = folderURL(args[1])
    if let refusal = DevelopmentGuard.refusal(for: folder) { fail(refusal) }
    let support = DevelopmentSupport.directory()
    let commands = Commands(support: support, deviceID: deviceID(support), client: "sprava-dev/0.1")
    var request = JSONObject([(key: "binder", value: .string(folder.path))])
    switch args[0] {
    case "slice":
        // Read-only: print the slice Sprava would publish, without writing it.
        let teka = Teka.read(folder)
        guard let catalog = teka.catalog else { fail("not a readable binder") }
        do {
            let key = SymmetricKeyFromHex.zero
            let at = args.count == 3 ? (Timestamp.parse(args[2]) ?? Date()) : Date()
            let (slice, _) = try HubLane.project(catalog: catalog, folderName: folder.lastPathComponent, closedOnce: [], key: key, now: at)
            print(JSONWriter.pretty(slice), terminator: "")
        } catch {
            fail("\(error)", code: 1)
        }
        return
    case "brain":
        // Register a brain client with propose access to this one binder; prints the token once.
        guard args.count == 3 else { fail(usage) }
        do {
            var clients = try MCPClients.load(support)
            let token = try clients.register(id: args[2], name: args[2], binders: [folder.path: "propose"])
            try clients.save(support)
            print(token)
        } catch {
            fail("\(error)", code: 1)
        }
        return
    case "adopt", "proposals":
        request.set("command", .string(args[0]))
    case "approve", "reject":
        guard args.count == 3 else { fail(usage) }
        let listed = commands.handle(JSONWriter.compact(.obj([("command", .str("proposals")), ("binder", .string(folder.path))])))
        let digest = (try? JSONParser.parse(listed).value["proposals"]?.arrayValue?
            .first { $0["id"]?.stringValue == args[2] }?["digest"]) ?? nil
        request.set("command", .string(args[0]))
        request.set("proposal", .string(args[2]))
        request.set("digest", digest ?? .null)
    case "complete", "drop":
        guard args.count == 3 else { fail(usage) }
        request.set("command", .str("apply"))
        request.set("op", .string(args[0]))
        request.set("args", .obj([("id", .string(args[2])), ("closed_at", .string(ISOTime.string(Date(), timeZone: TimeZone(identifier: "UTC")!))),
                                  ("source", .str("user"))]))
    default:
        fail(usage)
    }
    let reply = commands.handle(JSONWriter.compact(.object(request)))
    guard let value = try? JSONParser.parse(reply).value else { fail(reply, code: 1) }
    print(JSONWriter.pretty(value), terminator: "")
    if value["ok"] != .bool(true) { exit(1) }
}

/// A typed note, written exactly as the app writes one (capture-event-v0 §8.1). The CLI cannot prove itself to
/// the runtime, so the note's binder is shown as a hint only and the card asks for a binder.
func note(_ args: [String]) {
    var args = args
    var binder: String?
    if let i = args.firstIndex(of: "--binder") {
        guard i + 1 < args.count else { fail(usage) }
        binder = args[i + 1]
        args.removeSubrange(i...(i + 1))
    }
    guard !args.isEmpty else { fail(usage) }
    let support = SpravaPaths.supportDirectory()
    let producer = CaptureProducer(root: CaptureInbox.defaultRoot(support: support), deviceID: deviceID(support), support: support)
    do {
        let (event, _) = try producer.writeNote(args.joined(separator: " "), binderHint: binder, startedAt: Date())
        print(event["id"]?.stringValue ?? "")
    } catch {
        fail("\(error)", code: 1)
    }
}
