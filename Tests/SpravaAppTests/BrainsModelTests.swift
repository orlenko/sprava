import Foundation
import SpravaKit
@testable import SpravaApp
import Testing

/// The Brains page binds its displayed scope, direct command and manual configuration to one registration.
@MainActor
@Suite struct BrainsModelTests {
    @Test func editingTheClientIDWhileRegisteringKeepsTheTokenWithItsOriginalClient() async throws {
        var started: CheckedContinuation<Void, Never>?
        var response: CheckedContinuation<String, Error>?
        var sentIDs: [String] = []
        let client = RuntimeClient(answer: { text in
            let request = try JSONParser.parse(text).value
            if request["command"] == .str("register_client") {
                sentIDs.append(request["client_id"]?.stringValue ?? "")
                return try await withCheckedThrowingContinuation {
                    response = $0
                    started?.resume()
                    started = nil
                }
            }
            return #"{"ok":true,"clients":[]}"#
        })
        let model = BrainsModel(client: client, authenticate: {})
        model.clientID = "invented-first-client"
        model.chosen = [URL(fileURLWithPath: "/Invented/binder")]
        model.claude = { nil }
        let work = Task { await model.register() }
        await withCheckedContinuation { started = $0 }
        model.clientID = "invented-later-client"
        // A second click during the same request cannot replace its one-time token.
        await model.register()
        // Running an older registration cannot clear the new token when its delayed reply arrives.
        await model.runRegistration()
        #expect(model.message == nil)
        #expect(model.registration == nil)
        response?.resume(returning: #"{"ok":true,"token":"invented-token"}"#)
        await work.value
        #expect(sentIDs == ["invented-first-client"])
        #expect(model.registration?.arguments.last == "invented-first-client")
        #expect(model.registration?.arguments.contains("SPRAVA_CLIENT_TOKEN=invented-token") == true)
        #expect(model.registration?.binderPaths == ["/Invented/binder"])
        #expect(!model.canEditRegistrationChoices)
        #expect(!model.registering)
    }

    @Test func refusedAuthenticationDoesNotIssueAClientToken() async {
        enum Refusal: Error { case cancelled }
        var requests = 0
        let model = BrainsModel(client: RuntimeClient(answer: { _ in
            requests += 1
            return #"{"ok":true,"token":"invented-token"}"#
        }), authenticate: { throw Refusal.cancelled })
        model.chosen = [URL(fileURLWithPath: "/Invented/binder")]
        await model.register()
        #expect(requests == 0)
        #expect(model.registration == nil)
        #expect(model.message != nil)
        #expect(!model.registering)
    }

    @Test func authenticationPrecedesRegistrationAndKeepsTheApprovedScope() async throws {
        var authenticated = false
        var request: JSONValue?
        var model: BrainsModel!
        let client = RuntimeClient(answer: { text in
            let parsed = try JSONParser.parse(text).value
            if parsed["command"] == .str("register_client") {
                #expect(authenticated)
                request = parsed
                return #"{"ok":true,"token":"invented-token"}"#
            }
            return #"{"ok":true,"clients":[]}"#
        })
        model = BrainsModel(client: client, authenticate: {
            authenticated = true
            model.clientID = "invented-other-client"
            model.chosen = [URL(fileURLWithPath: "/Invented/other-binder")]
        })
        model.clientID = "invented-approved-client"
        model.chosen = [URL(fileURLWithPath: "/Invented/approved-binder")]
        await model.register()
        #expect(request?["client_id"] == .str("invented-approved-client"))
        #expect(request?["binders"]?["/Invented/approved-binder"] == .str("propose"))
        #expect(request?["binders"]?["/Invented/other-binder"] == nil)
    }

    @Test func wideningDocumentAccessRequiresAuthenticationButTurningItOffDoesNot() async {
        enum Refusal: Error { case cancelled }
        var commands: [String] = []
        let model = BrainsModel(client: RuntimeClient(answer: { text in
            let request = try JSONParser.parse(text).value
            commands.append(request["command"]?.stringValue ?? "")
            if request["command"] == .str("client_documents") {
                #expect(request["documents"] == .bool(false))
            }
            return #"{"ok":true,"clients":[]}"#
        }), authenticate: { throw Refusal.cancelled })
        let c = BrainsModel.Client(id: "invented-client", name: "Invented", binders: [:], documents: false)
        await model.setDocuments(c, true)
        #expect(!commands.contains("client_documents"))
        #expect(model.message != nil)
        await model.setDocuments(c, false)
        #expect(commands.filter { $0 == "client_documents" }.count == 1)
    }

    @Test func changingTheDraftNeverChangesThePendingRegistrationAndCancellingRevokesIt() async throws {
        var issued = 0
        var revoked: [String] = []
        let client = RuntimeClient(answer: { text in
            let r = try JSONParser.parse(text).value
            switch r["command"] {
            case .str("register_client"):
                issued += 1
                return #"{"ok":true,"token":"invented-token"}"#
            case .str("revoke_client"):
                revoked.append(r["client_id"]?.stringValue ?? "")
                return #"{"ok":true}"#
            default: return #"{"ok":true,"clients":[]}"#
            }
        })
        let model = BrainsModel(client: client, authenticate: {})
        model.clientID = "invented-approved-client"
        model.chosen = [URL(fileURLWithPath: "/Invented/approved-binder")]
        await model.register()
        let pending = try #require(model.registration)
        #expect(!model.canEditRegistrationChoices)
        model.clientID = "invented-other-client"
        model.chosen = [URL(fileURLWithPath: "/Invented/other-binder")]
        await model.register()
        #expect(issued == 1)
        #expect(model.registration == pending)
        #expect(pending.clientID == "invented-approved-client")
        #expect(pending.binderPaths == ["/Invented/approved-binder"])
        let config = try JSONParser.parse(pending.configuration).value
        let server = try #require(config["mcpServers"]?["sprava"])
        #expect(server["args"] == .array([.str("--client"), .str("invented-approved-client")]))
        #expect(server["env"]?["SPRAVA_CLIENT_TOKEN"] == .str("invented-token"))
        #expect(server["command"] == .str(BrainsModel.shimPath))
        let tokenIndex = try #require(pending.arguments.firstIndex(of: "SPRAVA_CLIENT_TOKEN=invented-token"))
        #expect(pending.arguments[tokenIndex + 1] == "--transport")
        await model.cancelRegistration()
        #expect(revoked == ["invented-approved-client"])
        #expect(model.registration == nil)
        #expect(model.canEditRegistrationChoices)
    }

    @Test func missingClaudeOffersConfigurationInsteadOfShellHistory() async {
        let model = BrainsModel()
        model.claude = { nil }
        model.registration = BrainsModel.Registration(arguments: ["claude"], clientID: "invented-client",
                                                      binderPaths: [], configuration: "{}")
        await model.runRegistration()
        #expect(model.message?.contains("~/.claude.json") == true)
        #expect(model.message?.contains("Terminal") == false)
        #expect(model.registration != nil)
    }

    @Test func theShownCommandKeepsAPathWithSpacesInOneArgument() {
        let args = ["claude", "mcp", "add", "--scope", "user", "--env", "SPRAVA_CLIENT_TOKEN=abc123", "sprava", "--",
                    "/Applications/Personal Apps/Sprava.app/Contents/MacOS/sprava-mcp", "--client", "claude-code-1"]
        #expect(BrainsModel.shellLine(args) == "claude mcp add --scope user --env SPRAVA_CLIENT_TOKEN=abc123 sprava -- "
            + "'/Applications/Personal Apps/Sprava.app/Contents/MacOS/sprava-mcp' --client claude-code-1")
        #expect(BrainsModel.shellLine(["it's", ""]) == #"'it'\''s' ''"#)
    }
}

/// "Run It for Me" runs Claude Code off the main actor, reads its output while it runs, and stops it after a timeout,
/// so a stalled or chatty child never leaves the app unresponsive (local review of the Brains page).
@MainActor
@Suite struct RunRegistrationTests {
    func model(_ program: String, _ args: [String], timeout: TimeInterval = 20) -> BrainsModel {
        let m = BrainsModel()
        m.claude = { URL(fileURLWithPath: program) }
        m.timeout = timeout
        m.registration = BrainsModel.Registration(arguments: ["claude"] + args, clientID: "invented-client",
                                                  binderPaths: ["/Invented/binder"], configuration: "{}")
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
        let run = Task { await m.runRegistration(); completed = true }
        // Observe a main-actor turn while the child is running, without a scheduling-speed threshold.
        while !m.running && !completed { await Task.yield() }
        #expect(m.running)
        #expect(!completed)
        await run.value
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(m.message?.contains("was stopped") == true)
        #expect(m.registration != nil)
        #expect(!m.running)
    }

    @Test func aChattyChildThatSucceedsConnects() async {
        let m = model("/bin/sh", ["-c", "yes | head -c 1000000; exit 0"])
        await m.runRegistration()
        #expect(m.message?.hasPrefix("Claude Code is connected") == true)
        #expect(m.registration == nil)
    }

    @Test func aFailureShowsWhatTheChildSaid() async {
        let m = model("/bin/sh", ["-c", "echo not today >&2; exit 3"])
        await m.runRegistration()
        #expect(m.message == "claude mcp add failed: not today\n")
        #expect(m.registration != nil)
    }
}
