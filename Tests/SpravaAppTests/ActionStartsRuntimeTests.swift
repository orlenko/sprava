import Foundation
import Shelf
@testable import SpravaApp
import SpravaKit
import SpravaTestSupport
import Testing

/// An action that needs the runtime checks first that it is there, and when it is not, starts it without asking
/// (decisions.md A16) and goes on, instead of sending the person through dialogs that cannot succeed. The start is
/// stood in for: no test shows UI or registers anything with launchd.
@MainActor
@Suite struct ActionStartsRuntimeTests {
    /// Records what the Shelf asked and did.
    final class Person {
        var starts = 0
        var binderQuestions: [URL?] = []
        var parentReads = 0
        var folderQuestions = 0
    }

    func model(_ runtime: StandInRuntime, _ person: Person, support: URL, parent: URL? = nil,
               starting: @escaping @MainActor () -> RuntimeKeeper.Outcome = { .running }) -> ShelfModel {
        let model = ShelfModel(support: support, client: runtime.client)
        model.startRuntime = { person.starts += 1; return starting() }
        model.askForBinder = { folder, _, _, _ in person.binderQuestions.append(folder); return ("blank", "garden-shed", "") }
        model.binderParent = { person.parentReads += 1; return parent }
        model.chooseFolders = { person.folderQuestions += 1; return [] }
        model.startWait = .milliseconds(200)
        return model
    }

    @Test func newBinderStartsTheRuntimeWithoutAskingAndGoesOn() async throws {
        let runtime = StandInRuntime()
        runtime.running = false
        runtime.answers["create_binder"] = { _ in #"{"ok":true,"binder":null,"proposal":null}"# }
        let person = Person()
        let parent = try temporaryFolder()
        let model = model(runtime, person, support: try temporaryFolder(), parent: parent,
                          starting: { runtime.running = true; return .running })
        await model.startNewBinder()
        #expect(person.starts == 1)
        #expect(person.binderQuestions == [nil] && person.parentReads == 1)
        #expect(runtime.sent.map { $0["command"]?.stringValue } == ["create_binder"])
        #expect(runtime.sent.first?["parent"]?.stringValue == parent.path && model.note == nil)
    }

    @Test(arguments: [
        (RuntimeKeeper.Outcome.failed("Move Sprava to Applications first."), "Move Sprava to Applications first."),
        (.needsApproval, "Login Items"),
        // Started, but the runtime does not answer within the wait.
        (.running, "has not started yet"),
    ])
    func aStartThatDoesNotBringTheRuntimeStopsAndSaysWhy(outcome: RuntimeKeeper.Outcome, said: String) async throws {
        let runtime = StandInRuntime()
        runtime.running = false
        let person = Person()
        let model = model(runtime, person, support: try temporaryFolder(), parent: try temporaryFolder(), starting: { outcome })
        await model.startNewBinder()
        #expect(person.starts == 1 && person.binderQuestions.isEmpty && person.parentReads == 0)
        #expect(runtime.sent.isEmpty)
        #expect(model.note?.contains(said) == true)
    }

    @Test func addFolderWithARuntimeThatCannotStartSendsNothing() async throws {
        let support = try temporaryFolder()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "kitchen-reno")
        let empty = try temporaryFolder()
        let runtime = StandInRuntime()
        runtime.running = false
        let person = Person()
        let model = model(runtime, person, support: support, starting: { .failed("Move Sprava to Applications first.") })
        await model.add([binder, empty])
        #expect(person.starts == 1 && person.binderQuestions.isEmpty)
        #expect(runtime.sent.isEmpty && model.rows.isEmpty)
        #expect(model.note?.contains("Nothing was added") == true)
        // The panel path does not open the panel either.
        await model.addFolder()
        #expect(person.starts == 2 && person.folderQuestions == 0 && runtime.sent.isEmpty)
    }

    @Test func addFolderStartsTheRuntimeAndGoesOn() async throws {
        let support = try temporaryFolder()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "kitchen-reno")
        let runtime = StandInRuntime()
        runtime.running = false
        runtime.answers["shelf_add"] = { request in
            try? ShelfStore(supportDirectory: support).add(URL(fileURLWithPath: request["binder"]!.stringValue!, isDirectory: true))
            return #"{"ok":true}"#
        }
        let person = Person()
        let model = model(runtime, person, support: support, starting: { runtime.running = true; return .running })
        await model.add([binder])
        #expect(runtime.sent.map { $0["command"]?.stringValue } == ["shelf_add"])
        #expect(model.rows.map(\.folder.standardizedFileURL) == [binder.standardizedFileURL] && model.note == nil)
    }

    @Test func aRunningRuntimeIsNotStarted() async throws {
        let runtime = StandInRuntime()
        let person = Person()
        let model = model(runtime, person, support: try temporaryFolder())
        await model.addFolder()
        #expect(runtime.pings == 1 && person.starts == 0 && person.folderQuestions == 1)
    }

    @Test(arguments: [false, true])
    func aSilentRuntimeCannotOpenNewBinderDialogs(startReportsRunning: Bool) async throws {
        let person = Person()
        var commands: [String] = []
        let client = RuntimeClient(answer: { text in
            commands.append(try JSONParser.parse(text).value["command"]!.stringValue!)
            throw RuntimeClient.Failure(message: "No reply", kind: .timedOut)
        })
        let model = ShelfModel(support: try temporaryFolder(), client: client)
        let parent = try temporaryFolder()
        model.askForBinder = { _, _, _, _ in person.binderQuestions.append(nil); return ("blank", "garden-shed", "") }
        model.binderParent = { person.parentReads += 1; return parent }
        model.startRuntime = { person.starts += 1; return startReportsRunning ? .running : .failed(RuntimeKeeper.noBeat) }
        model.startWait = .zero
        await model.startNewBinder()
        #expect(person.starts == 1)
        #expect(person.binderQuestions.isEmpty && person.parentReads == 0)
        #expect(commands.allSatisfy { $0 == "ping" })
        #expect(model.note != nil)
    }

    @Test func anotherNewBinderClickCannotStartASecondSetOfDialogs() async throws {
        let runtime = StandInRuntime()
        runtime.running = false
        runtime.answers["create_binder"] = { _ in #"{"ok":true,"binder":null,"proposal":null}"# }
        let person = Person()
        let model = model(runtime, person, support: try temporaryFolder(), parent: try temporaryFolder())
        var start: CheckedContinuation<RuntimeKeeper.Outcome, Never>?
        model.startRuntime = {
            person.starts += 1
            return await withCheckedContinuation { start = $0 }
        }
        let first = Task { await model.startNewBinder() }
        while start == nil { await Task.yield() }
        #expect(model.creatingBinder && person.binderQuestions.isEmpty)
        await model.startNewBinder()
        runtime.running = true
        start?.resume(returning: .running)
        await first.value
        #expect(!model.creatingBinder && person.starts == 1)
        #expect(person.binderQuestions.count == 1 && person.parentReads == 1)
        #expect(runtime.sent.count == 1)
    }

    @Test func theMessageForNoRuntimeLeavesOutTheSystemsWords() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4099,
                            userInfo: [NSLocalizedDescriptionKey: "Couldn't communicate with a helper application."])
        let failure = RuntimeClient.Failure.notRunning(error)
        #expect(!failure.description.contains(error.localizedDescription))
        // One plain line: the code goes to the log, not to the page.
        #expect(failure.description == RuntimeClient.Failure.notRunningLine)
        #expect(!failure.description.contains("4099") && !failure.description.contains("error"))
        #expect(failure.kind == .notRunning)
    }

    @Test func aRefusedPingStillMeansTheRuntimeIsThere() async {
        let refusing = RuntimeClient(answer: { _ in #"{"ok":false,"error":"unknown command ping"}"# })
        #expect(await refusing.presence() == .answers)
        let absent = RuntimeClient(answer: { _ in throw RuntimeClient.Failure.notRunning(NSError(domain: NSCocoaErrorDomain, code: 4099)) })
        #expect(await absent.presence() == .notRunning)
    }

    @Test func presenceIsPassiveButAFailedActionStillRequestsStartup() async {
        var starts = 0
        let absent = RuntimeClient(answer: { _ in
            throw RuntimeClient.Failure.notRunning(NSError(domain: NSCocoaErrorDomain, code: 4099))
        }, onNotRunning: { starts += 1 })
        #expect(await absent.presence() == .notRunning)
        #expect(starts == 0)
        do { _ = try await absent.global("create_binder") }
        catch { }
        #expect(starts == 1)
    }
}
