import Foundation
import SpravaKit
@testable import SpravaApp
import Testing

/// A runtime stand-in that keeps a client registry the way the runtime does: registering an id again renews it.
@MainActor
final class InventedRuntime {
    var clients: [(id: String, binders: [String])] = []
    var commands: [JSONValue] = []
    var refuseRegistration: String?

    lazy var client = RuntimeClient(answer: { text in try self.answer(text) })

    func answer(_ text: String) throws -> String {
        let r = try JSONParser.parse(text).value
        commands.append(r)
        switch r["command"]?.stringValue {
        case "register_client":
            if let refuseRegistration { return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str(refuseRegistration))])) }
            let id = r["client_id"]?.stringValue ?? ""
            clients.removeAll { $0.id == id }
            clients.append((id, (r["binders"]?.objectValue?.entries ?? []).map(\.key)))
            return #"{"ok":true,"token":"invented-token-\#(commands.count)"}"#
        case "revoke_client":
            clients.removeAll { $0.id == r["client_id"]?.stringValue }
            return #"{"ok":true,"withdrawn":0}"#
        case "list_clients":
            return JSONWriter.compact(.obj([("ok", .bool(true)), ("clients", .array(clients.map { c in
                .obj([("id", .str(c.id)), ("name", .str("Claude Code")),
                      ("binders", .obj(c.binders.map { ($0, .str("propose")) })), ("documents", .bool(false))])
            }))]))
        default: return #"{"ok":true}"#
        }
    }

    var registrations: [JSONValue] { commands.filter { $0["command"] == .str("register_client") } }
}

/// The Brains page: one button connects Claude Code, picks its id itself, and connecting again renews it.
@MainActor
@Suite struct BrainsModelTests {
    /// A model whose Claude Code is a recorder: it records each run and exits with `exit`.
    func model(_ runtime: InventedRuntime, exit: Int32 = 0, runs: Recorder = Recorder()) -> BrainsModel {
        let m = BrainsModel(client: runtime.client, authenticate: {})
        m.claude = { URL(fileURLWithPath: "/Invented/bin/claude") }
        m.run = { _, arguments, _ in
            await runs.add(arguments)
            return ChildRun.Outcome(ending: .exited(exit), stdout: Data(), stderr: Data("invented refusal".utf8))
        }
        return m
    }

    actor Recorder {
        var runs: [[String]] = []
        func add(_ arguments: [String]) { runs.append(arguments) }
    }

    @Test func connectingTwiceWithTheSameBindersSucceedsAndNeverSaysExists() async throws {
        let runtime = InventedRuntime()
        let runs = Recorder()
        let m = model(runtime, runs: runs)
        m.chosen = ["/Invented/acme"]
        await m.connect()
        #expect(m.message == "Claude Code is connected. Start a new Claude Code session to use it.")
        #expect(m.claudeCode?.binders.keys.sorted() == ["/Invented/acme"])
        await m.connect()
        #expect(m.message == "Claude Code is connected. Start a new Claude Code session to use it.")
        #expect(runtime.registrations.count == 2)
        #expect(runtime.registrations.allSatisfy { $0["client_id"] == .str(BrainsModel.claudeCodeID) })
        #expect(m.clients.count == 1)
        // Each connect removes an earlier entry first, then adds the new one with the new key.
        let recorded = await runs.runs
        #expect(recorded.count == 4)
        #expect(recorded[2] == Array(BrainsModel.removeArguments.dropFirst()))
        #expect(recorded[3].contains("SPRAVA_CLIENT_TOKEN=invented-token-3"))
        #expect(recorded[3].suffix(2) == ["--client", BrainsModel.claudeCodeID])
        #expect(m.registration == nil)
    }

    @Test func changingTheBindersUpdatesTheScopeAndTheTicksStartFromIt() async {
        let runtime = InventedRuntime()
        let m = model(runtime)
        m.chosen = ["/Invented/acme"]
        await m.connect()
        m.choose(URL(fileURLWithPath: "/Invented/acme"), false)
        m.choose(URL(fileURLWithPath: "/Invented/household"), true)
        await m.connect()
        #expect(m.claudeCode?.binders.keys.sorted() == ["/Invented/household"])
        #expect(runtime.registrations.last?["binders"] == .obj([("/Invented/household", .str("propose"))]))
        // A page opened later ticks the binders Claude Code already sees.
        let later = model(runtime)
        await later.load()
        #expect(later.chosen == ["/Invented/household"])
    }

    @Test func aRefusalFromTheRuntimeReachesThePageInPlainWords() async {
        let runtime = InventedRuntime()
        runtime.refuseRegistration = "client claude-code-1 exists"
        let m = model(runtime)
        m.chosen = ["/Invented/acme"]
        await m.connect()
        let said = m.message ?? ""
        #expect(!said.contains("exists") && !said.contains("client"))
        #expect(said.first?.isUppercase == true)
        #expect(m.registration == nil)
        #expect(!m.busy)
    }

    @Test func refusedAuthenticationChangesNothing() async {
        enum Refusal: Error { case cancelled }
        let runtime = InventedRuntime()
        let m = BrainsModel(client: runtime.client, authenticate: { throw Refusal.cancelled })
        m.chosen = ["/Invented/acme"]
        await m.connect()
        #expect(runtime.commands.isEmpty)
        #expect(m.message?.hasPrefix("Connecting needs your Touch ID") == true)
        #expect(!m.busy)
    }

    @Test func authenticationPrecedesRegistrationAndKeepsTheApprovedScope() async throws {
        let runtime = InventedRuntime()
        var m: BrainsModel!
        m = BrainsModel(client: runtime.client, authenticate: {
            #expect(runtime.commands.isEmpty)
            m.chosen = ["/Invented/other-binder"]
        })
        m.claude = { nil }
        m.chosen = ["/Invented/approved-binder"]
        await m.connect()
        let request = try #require(runtime.registrations.first)
        #expect(request["binders"]?["/Invented/approved-binder"] == .str("propose"))
        #expect(request["binders"]?["/Invented/other-binder"] == nil)
    }

    @Test func aSecondClickWhileConnectingIsIgnored() async {
        let runtime = InventedRuntime()
        var started: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        let m = BrainsModel(client: runtime.client, authenticate: {
            await withCheckedContinuation { c in
                release = c
                started?.resume()
            }
        })
        m.claude = { nil }
        m.chosen = ["/Invented/acme"]
        let work = Task { await m.connect() }
        await withCheckedContinuation { started = $0 }
        #expect(!m.canConnect)
        await m.connect()
        m.choose(URL(fileURLWithPath: "/Invented/household"), true)
        release?.resume()
        await work.value
        #expect(runtime.registrations.count == 1)
        #expect(runtime.registrations.first?["binders"] == .obj([("/Invented/acme", .str("propose"))]))
    }

    @Test func missingClaudeLeavesTheSetupToAddByHand() async throws {
        let runtime = InventedRuntime()
        let m = model(runtime)
        m.claude = { nil }
        m.chosen = ["/Invented/acme"]
        await m.connect()
        #expect(m.message?.contains("~/.claude.json") == true)
        #expect(m.message?.contains("Terminal") == false)
        let pending = try #require(m.registration)
        #expect(pending.binderPaths == ["/Invented/acme"])
        let config = try JSONParser.parse(pending.configuration).value
        let server = try #require(config["mcpServers"]?["sprava"])
        #expect(server["args"] == .array([.str("--client"), .str(BrainsModel.claudeCodeID)]))
        #expect(server["env"]?["SPRAVA_CLIENT_TOKEN"] == .str("invented-token-1"))
        #expect(server["command"] == .str(BrainsModel.shimPath))
        // Claude Code still counts as connected: Sprava holds the scope, the setup finishes it.
        #expect(m.claudeCode != nil)
    }

    @Test func aRefusedSetupShowsWhatClaudeCodeSaidAndCanBeTriedAgain() async {
        let runtime = InventedRuntime()
        let runs = Recorder()
        let m = model(runtime, exit: 3, runs: runs)
        m.chosen = ["/Invented/acme"]
        await m.connect()
        #expect(m.message?.hasPrefix("Claude Code did not accept the setup (invented refusal).") == true)
        #expect(m.registration != nil)
        await m.tryAgain()
        #expect(await runs.runs.count == 4)
        #expect(runtime.registrations.count == 1)
    }

    @Test func disconnectingRevokesAndRemovesTheEntry() async throws {
        let runtime = InventedRuntime()
        let runs = Recorder()
        let m = model(runtime, runs: runs)
        m.chosen = ["/Invented/acme"]
        await m.connect()
        let c = try #require(m.claudeCode)
        await m.disconnect(c)
        #expect(m.claudeCode == nil)
        #expect(m.chosen.isEmpty)
        #expect(runtime.commands.contains { $0["command"] == .str("revoke_client") && $0["client_id"] == .str(BrainsModel.claudeCodeID) })
        #expect(await runs.runs.last == Array(BrainsModel.removeArguments.dropFirst()))
    }

    @Test func wideningDocumentAccessRequiresAuthenticationButTurningItOffDoesNot() async {
        enum Refusal: Error { case cancelled }
        let runtime = InventedRuntime()
        let m = BrainsModel(client: runtime.client, authenticate: { throw Refusal.cancelled })
        let c = BrainsModel.Client(id: "invented-client", name: "Invented", binders: [:], documents: false)
        await m.setDocuments(c, true)
        #expect(!runtime.commands.contains { $0["command"] == .str("client_documents") })
        #expect(m.message?.first?.isUppercase == true)
        await m.setDocuments(c, false)
        #expect(runtime.commands.filter { $0["command"] == .str("client_documents") }.count == 1)
        #expect(runtime.commands.first { $0["command"] == .str("client_documents") }?["documents"] == .bool(false))
    }

    @Test func theShownCommandKeepsAPathWithSpacesInOneArgument() {
        let args = ["claude", "mcp", "add", "--scope", "user", "--env", "SPRAVA_CLIENT_TOKEN=abc123", "sprava", "--",
                    "/Applications/Personal Apps/Sprava.app/Contents/MacOS/sprava-mcp", "--client", "claude-code-1"]
        #expect(BrainsModel.shellLine(args) == "claude mcp add --scope user --env SPRAVA_CLIENT_TOKEN=abc123 sprava -- "
            + "'/Applications/Personal Apps/Sprava.app/Contents/MacOS/sprava-mcp' --client claude-code-1")
        #expect(BrainsModel.shellLine(["it's", ""]) == #"'it'\''s' ''"#)
    }
}

/// Claude Code runs off the main actor with its output read while it runs, and is stopped after a timeout, so a
/// stalled or chatty child never leaves the app unresponsive (local review of the Brains page).
@MainActor
@Suite struct RunRegistrationTests {
    /// A model whose Claude Code is `program` with `args`, whatever Sprava asks of it.
    func model(_ program: String, _ args: [String], timeout: TimeInterval = 20) -> BrainsModel {
        let m = BrainsModel(client: InventedRuntime().client, authenticate: {})
        m.claude = { URL(fileURLWithPath: program) }
        m.timeout = timeout
        m.run = { program, _, timeout in try await ChildRun(executable: program, arguments: args, timeout: timeout).run() }
        m.registration = BrainsModel.Registration(arguments: ["claude"], clientID: BrainsModel.claudeCodeID,
                                                  binderPaths: ["/Invented/acme"], configuration: "{}")
        return m
    }

    @Test func aChildThatWritesMoreThanAPipeHoldsOnBothOutputsCompletes() async throws {
        let r = try await ChildRun(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", "yes | head -c 1000000; yes | head -c 1000000 >&2; exit 0"], timeout: 20).run()
        #expect(r.ending == .exited(0))
        #expect(r.stdout.count == 64 * 1024)
        #expect(r.stderr.count == 64 * 1024)
    }

    @Test func aChildThatNeverExitsIsStoppedAndTheMainActorStaysFree() async {
        let m = model("/bin/sleep", ["60"], timeout: 1.5)
        let started = Date()
        var completed = false
        let run = Task { await m.tryAgain(); completed = true }
        // Observe a main-actor turn while the child is running, without a scheduling-speed threshold.
        while !m.busy && !completed { await Task.yield() }
        #expect(m.busy)
        #expect(!completed)
        await run.value
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(m.message?.contains("was stopped") == true)
        #expect(m.registration != nil)
        #expect(!m.busy)
    }

    @Test func aChattyChildThatSucceedsConnects() async {
        let m = model("/bin/sh", ["-c", "yes | head -c 1000000; exit 0"])
        await m.tryAgain()
        #expect(m.message?.hasPrefix("Claude Code is connected") == true)
        #expect(m.registration == nil)
    }
}
