import Foundation
import CryptoKit
import SpravaCore

enum SymmetricKeyFromHex { static let zero = SymmetricKey(data: Data(count: 32)) }

// `sprava`: the read-only Shelf and Now pages of MVP increment 1 (docs/mvp.md section 5).
// Nothing here writes inside a binder. `shelf add` and `shelf remove` write only Sprava's own state.

let usage = """
usage: sprava shelf [--archived]          every binder: state, last change, overdue and Nudge counts
       sprava shelf add <folder>          add a folder to the shelf (Sprava's own state only)
       sprava shelf remove <folder>       take it off the shelf
       sprava now <folder> [--today YYYY-MM-DD]
                                          one binder's items in the eight buckets
       sprava check <folder>              the binder's state and rule findings (ids and counts only)
       sprava note <text> [--binder <name>] write a typed note as a capture event; without the app's
                                          notice its card is "unverified" and asks for a binder
       sprava import-holos [--file <json>] developer only: write holos dictations as capture events, from
                                          `voiceislocal history list --json` (or a saved copy of its output)
       sprava clerk <text> [--locale <tag>] [--binder <name>=<description>]...
                                          developer only: run the on-device clerk on invented text and print
                                          what it read; nothing is filed
       sprava dev <command> <folder> ...  development only, on invented copies: adopt, proposals,
                                          approve <id>, reject <id>, complete <item-id>, drop <item-id>.
                                          Refuses any folder in lifeproj's registry.

The shelf lists the live tekas in lifeproj's registry ($CMIRROR_CONFIG or ~/.config/cmirror/config.toml),
read-only, plus folders added with `sprava shelf add`.
"""

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func folderURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
}

func todayFrom(_ args: inout [String]) -> CalendarDate {
    if let i = args.firstIndex(of: "--today") {
        guard i + 1 < args.count, let date = CalendarDate.strict(args[i + 1]) else { fail("--today needs YYYY-MM-DD") }
        args.removeSubrange(i...(i + 1))
        return date
    }
    return CalendarDate.today()
}

func ago(_ date: Date?) -> String {
    guard let date else { return "-" }
    let seconds = max(0, Date().timeIntervalSince(date))
    switch seconds {
    case ..<3600: return "\(Int(seconds / 60))m ago"
    case ..<86_400: return "\(Int(seconds / 3600))h ago"
    default: return "\(Int(seconds / 86_400))d ago"
    }
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func shelf(_ args: [String]) {
    var args = args
    if let sub = args.first, sub == "add" || sub == "remove" {
        guard args.count == 2 else { fail(usage) }
        let store = ShelfStore()
        let folder = folderURL(args[1])
        do {
            if sub == "add" {
                let teka = Teka.read(folder)
                if teka.state == .notATeka { fail("\(folder.path): no catalog.json, so not a teka") }
                try store.add(folder)
                print("added \(teka.name) (\(teka.state.label))")
            } else {
                try store.remove(folder)
                print("removed \(folder.path)")
            }
        } catch {
            fail("could not update the shelf: \(error.localizedDescription)", code: 1)
        }
        return
    }
    let includeArchived = args.contains("--archived")
    args.removeAll { $0 == "--archived" }
    guard args.isEmpty else { fail(usage) }

    let registryURL = LifeprojRegistry.defaultPath()
    var registry: LifeprojRegistry?
    var note: String?
    if FileManager.default.fileExists(atPath: registryURL.path) {
        do { registry = try LifeprojRegistry.load(from: registryURL) } catch { note = "registry unreadable: \(error.localizedDescription)" }
    }
    let rows = Shelf.rows(registry: registry, picked: ShelfStore().pickedFolders(), includeArchived: includeArchived)
    let today = CalendarDate.today()
    if rows.isEmpty {
        print("The shelf is empty. Add a binder with `sprava shelf add <folder>`.")
    }
    let width = min(32, rows.map(\.name.count).max() ?? 4)
    for row in rows {
        let page = row.teka.nowPage(today: today)
        let counts = row.teka.items.isEmpty && row.teka.catalog == nil
            ? ""
            : "overdue \(page.count(.overdue)) · nudge \(page.count(.nudge)) · today \(page.count(.today))"
        let tag = row.archived ? " [archived]" : ""
        print("\(pad(row.name, width))  \(pad(row.stateLabel, 16))  \(pad(ago(row.teka.modified), 8))  \(counts)\(tag)")
    }
    if let note { print("\nNote: \(note)") }
}

func now(_ args: [String]) {
    var args = args
    let today = todayFrom(&args)
    guard args.count == 1 else { fail(usage) }
    let teka = Teka.read(folderURL(args[0]))
    switch teka.state {
    case .notATeka, .corrupt: fail("\(teka.name): \(teka.state.label) (\(teka.reasons.joined(separator: "; ")))", code: 1)
    default: break
    }
    print("\(teka.name) · \(teka.level?.label ?? "?") · \(teka.isAdopted ? teka.state.label : "not yet adopted") · \(today)")
    let page = teka.nowPage(today: today)
    for bucket in Bucket.allCases {
        if bucket == .recentlyClosed {
            guard !page.closed.isEmpty else { continue }
            print("\n\(bucket.title.uppercased())")
            for entry in page.closed {
                print("  \(pad(entry.closedOn?.description ?? "date unknown", 12))  \(entry.title)  (\(entry.action))")
            }
            continue
        }
        let items = page.items[bucket, default: []]
        guard !items.isEmpty else { continue }
        print("\n\(bucket.title.uppercased())")
        for item in items {
            let mark = item.priority == .high ? "!" : " "
            var date = item.due?.description ?? "-"
            if bucket == .nudge || bucket == .waiting { date = item.followUpAt.map { "chase \($0)" } ?? "chase now" }
            var line = "  \(mark) \(pad(date, 16))  \(item.title)"
            if let party = item.waitingOn, bucket == .nudge || bucket == .waiting { line += "  ← \(party)" }
            if item.hasRecurrence { line += "  (repeats)" }
            print(line)
        }
    }
    if page.hiddenCount > 0 { print("\n\(page.hiddenCount) dismissed item(s) hidden") }
    if teka.state < .ready, teka.state != .needsMigration || teka.isAdopted {
        print("\nState: \(teka.state.label): \(teka.reasons.joined(separator: "; "))")
    }
}

func check(_ args: [String]) {
    guard args.count == 1 else { fail(usage) }
    let teka = Teka.read(folderURL(args[0]))
    print("\(teka.name): \(teka.state.label)\(teka.level.map { " (\($0.label))" } ?? "")")
    for reason in teka.reasons { print("  - \(reason)") }
    let s = teka.safety
    if !s.isSafe {
        print("  unsafe JSON: \(s.duplicateKeys.count) duplicate key(s), \(s.loneSurrogates.count) lone surrogate(s), \(s.unsafeNumbers.count) unsafe number(s)")
    }
    for finding in teka.findings { print("  \(finding)") }
    exit(teka.state <= .corrupt ? 1 : 0)
}

/// Development commands: the same `Commands` the runtime runs for the app, in-process. Never on a folder that
/// lifeproj's registry lists, so a live binder is only ever written by the installed runtime.
func dev(_ args: [String]) {
    guard args.count >= 2 else { fail(usage) }
    let folder = folderURL(args[1])
    let registryURL = LifeprojRegistry.defaultPath()
    if let registry = try? LifeprojRegistry.load(from: registryURL),
       registry.entries.contains(where: { $0.workingDir.map { folderURL($0) } == folder }) {
        fail("\(folder.path) is in lifeproj's registry; development commands work on invented copies only")
    }
    let support = SpravaPaths.supportDirectory()
    let commands = Commands(support: support, deviceID: DeviceID.load(support: support), client: "sprava-dev/0.1")
    var request = JSONObject([(key: "binder", value: .string(folder.path))])
    switch args[0] {
    case "slice":
        // Read-only: print the slice Sprava would publish, without writing it.
        let teka = Teka.read(folder)
        guard let catalog = teka.catalog else { fail("not a readable teka") }
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
        var clients = MCPClients.load(support)
        do {
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
    let producer = CaptureProducer(root: CaptureInbox.defaultRoot(support: support), deviceID: DeviceID.load(support: support), support: support)
    do {
        let (event, _) = try producer.writeNote(args.joined(separator: " "), binderHint: binder, startedAt: Date())
        print(event["id"]?.stringValue ?? "")
    } catch {
        fail("\(error)", code: 1)
    }
}

/// The developer-only importer (capture-event-v0 §7.8). It only ever runs the read-only `history list`.
func importHolos(_ args: [String]) {
    let data: Data
    if let i = args.firstIndex(of: "--file"), i + 1 < args.count {
        guard let d = FileManager.default.contents(atPath: (args[i + 1] as NSString).expandingTildeInPath) else { fail("cannot read \(args[i + 1])") }
        data = d
    } else {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["voiceislocal", "history", "list", "--json"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice   // "Note:" lines are ignored
        do { try task.run() } catch { fail("voiceislocal is not on the PATH", code: 1) }
        data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { fail("voiceislocal history list failed", code: 1) }
    }
    let support = SpravaPaths.supportDirectory()
    let root = CaptureInbox.defaultRoot(support: support)
    do {
        let r = try HolosImporter(root: root, support: support).importHistory(data, inbox: CaptureInbox(root: root, support: support))
        if r.stoppedForGood { print("holos writes its own capture events now; the importer has stopped for good") }
        else { print("written \(r.written), already imported \(r.skipped), unreadable \(r.unreadable)") }
    } catch {
        fail("\(error)", code: 1)
    }
}

/// The clerk on invented text, for the release-gate fixtures (architecture 5.3). Nothing is filed.
func clerk(_ args: [String]) {
    var args = args
    var locale = "en-CA"
    var filing: [FilingBinder] = []
    while let i = args.firstIndex(where: { $0 == "--locale" || $0 == "--binder" }), i + 1 < args.count {
        if args[i] == "--locale" { locale = args[i + 1] } else {
            let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail(usage) }
            filing.append(FilingBinder(name: parts[0], description: parts[1], folder: URL(fileURLWithPath: "/dev/null"),
                                       words: FilingBinder.significantWords(parts[1])))
        }
        args.removeSubrange(i...(i + 1))
    }
    guard !args.isEmpty else { fail(usage) }
    let model: AppleClerkModel
    switch AppleClerkModel.load() {
    case .success(let m): model = m
    case .failure(let e): fail("the clerk cannot run: \(e)", code: 1)
    }
    var o = JSONObject()
    o.set("id", .string(UUIDv7.make()))
    o.set("source", .obj([("app", .str("sprava")), ("kind", .str("text")), ("ref", .str("dev")), ("revision", .str("dev"))]))
    o.set("captured_at", .string(CaptureProducer.offsetTime(Date())))
    o.set("locale", .string(locale))
    o.set("text", .string(args.joined(separator: " ")))
    o.set("sensitivity", .str("unmarked"))
    let event = CaptureEvent(raw: o, url: URL(fileURLWithPath: "/dev/null"), digest: "")
    let started = Date()
    let offered = filing
    let interp = runBlocking { await Clerk(model: model).read(event, filing: offered, hint: nil) }
    var record = CaptureInbox.record(interp)
    record.set("calls", .int(interp.calls))
    record.set("seconds", .number(JSONNumber(text: String(format: "%.2f", Date().timeIntervalSince(started)))))
    print(JSONWriter.pretty(.object(record)), terminator: "")
}

final class RunBox<T>: @unchecked Sendable { var value: T? }

func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = RunBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        box.value = await body()
        done.signal()
    }
    done.wait()
    return box.value!
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }
arguments.removeFirst()
switch command {
case "shelf": shelf(arguments)
case "now": now(arguments)
case "check": check(arguments)
case "dev": dev(arguments)
case "note": note(arguments)
case "import-holos": importHolos(arguments)
case "clerk": clerk(arguments)
case "-h", "--help", "help": print(usage)
default: fail(usage)
}
