import Foundation
import Shelf
@testable import SpravaApp
import SpravaKit
import SpravaTestSupport
import Testing

/// An action that needs the runtime checks first that it is there, and when it is not, offers to turn background work
/// on instead of sending the person through dialogs that cannot succeed. The alert and the registration are stood in
/// for: no test shows UI or registers anything with launchd.
@MainActor
@Suite struct BackgroundWorkOfferTests {
    /// Records what the Shelf asked and did, with the person's answers given in advance.
    final class Person {
        var turnOn = false
        var offers = 0
        var turnOns = 0
        var binderQuestions: [URL?] = []
        var parentQuestions = 0
        var folderQuestions = 0
    }

    func model(_ runtime: StandInRuntime, _ person: Person, support: URL, parent: URL? = nil,
               turningOn: @escaping @MainActor () -> BackgroundWork.TurnOn = { .registered }) -> ShelfModel {
        let model = ShelfModel(support: support, client: runtime.client)
        model.offerBackgroundWork = { person.offers += 1; return person.turnOn }
        model.turnOnBackgroundWork = { person.turnOns += 1; return turningOn() }
        model.askForBinder = { folder, _ in person.binderQuestions.append(folder); return ("blank", "garden-shed") }
        model.chooseParent = { person.parentQuestions += 1; return parent }
        model.chooseFolders = { person.folderQuestions += 1; return [] }
        model.startWait = .milliseconds(200)
        return model
    }

    @Test func newBinderWithTheRuntimeDownAsksNothingAndSendsNothing() async throws {
        let runtime = StandInRuntime()
        runtime.running = false
        let person = Person()
        let model = model(runtime, person, support: try temporaryFolder(), parent: try temporaryFolder())
        await model.startNewBinder()
        #expect(person.offers == 1 && person.turnOns == 0)
        #expect(person.binderQuestions.isEmpty && person.parentQuestions == 0)
        #expect(runtime.sent.isEmpty && model.note == nil)
    }

    @Test func newBinderGoesOnOnceBackgroundWorkIsTurnedOn() async throws {
        let runtime = StandInRuntime()
        runtime.running = false
        runtime.answers["create_binder"] = { _ in #"{"ok":true,"binder":null,"proposal":null}"# }
        let person = Person()
        person.turnOn = true
        let parent = try temporaryFolder()
        let model = model(runtime, person, support: try temporaryFolder(), parent: parent,
                          turningOn: { runtime.running = true; return .registered })
        await model.startNewBinder()
        #expect(person.offers == 1 && person.turnOns == 1)
        #expect(person.binderQuestions == [nil] && person.parentQuestions == 1)
        #expect(runtime.sent.map { $0["command"]?.stringValue } == ["create_binder"])
        #expect(runtime.sent.first?["parent"]?.stringValue == parent.path && model.note == nil)
    }

    @Test(arguments: [
        (BackgroundWork.TurnOn.failed("Move Sprava to Applications first."), "Move Sprava to Applications first."),
        (.needsApproval, "Login Items"),
        // Registered, but the runtime does not answer within the wait.
        (.registered, "has not started yet"),
    ])
    func aTurnOnThatDoesNotBringTheRuntimeStopsAndSaysWhy(outcome: BackgroundWork.TurnOn, said: String) async throws {
        let runtime = StandInRuntime()
        runtime.running = false
        let person = Person()
        person.turnOn = true
        let model = model(runtime, person, support: try temporaryFolder(), parent: try temporaryFolder(), turningOn: { outcome })
        await model.startNewBinder()
        #expect(person.turnOns == 1 && person.binderQuestions.isEmpty && person.parentQuestions == 0)
        #expect(runtime.sent.isEmpty)
        #expect(model.note?.contains(said) == true)
    }

    @Test func addFolderWithTheRuntimeDownSendsNothing() async throws {
        let support = try temporaryFolder()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "kitchen-reno")
        let empty = try temporaryFolder()
        let runtime = StandInRuntime()
        runtime.running = false
        let person = Person()
        let model = model(runtime, person, support: support)
        await model.add([binder, empty])
        #expect(person.offers == 1 && person.binderQuestions.isEmpty)
        #expect(runtime.sent.isEmpty && model.rows.isEmpty)
        #expect(model.note?.contains("Nothing was added") == true)
        // The panel path does not open the panel either.
        await model.addFolder()
        #expect(person.offers == 2 && person.folderQuestions == 0 && runtime.sent.isEmpty)
    }

    @Test func addFolderGoesOnOnceBackgroundWorkIsTurnedOn() async throws {
        let support = try temporaryFolder()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "kitchen-reno")
        let runtime = StandInRuntime()
        runtime.running = false
        runtime.answers["shelf_add"] = { request in
            try? ShelfStore(supportDirectory: support).add(URL(fileURLWithPath: request["binder"]!.stringValue!, isDirectory: true))
            return #"{"ok":true}"#
        }
        let person = Person()
        person.turnOn = true
        let model = model(runtime, person, support: support, turningOn: { runtime.running = true; return .registered })
        await model.add([binder])
        #expect(runtime.sent.map { $0["command"]?.stringValue } == ["shelf_add"])
        #expect(model.rows.map(\.folder.standardizedFileURL) == [binder.standardizedFileURL] && model.note == nil)
    }

    @Test func aRunningRuntimeIsNotOfferedAnything() async throws {
        let runtime = StandInRuntime()
        let person = Person()
        let model = model(runtime, person, support: try temporaryFolder())
        await model.addFolder()
        #expect(runtime.pings == 1 && person.offers == 0 && person.folderQuestions == 1)
    }

    @Test func theMessageForNoRuntimeLeavesOutTheSystemsWords() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4099,
                            userInfo: [NSLocalizedDescriptionKey: "Couldn't communicate with a helper application."])
        let failure = RuntimeClient.Failure.notRunning(error)
        #expect(!failure.description.contains(error.localizedDescription))
        #expect(failure.description.hasPrefix("Sprava's background part is not running.") && failure.description.contains("4099"))
        #expect(failure.kind == .notRunning)
    }

    @Test func aRefusedPingStillMeansTheRuntimeIsThere() async {
        let refusing = RuntimeClient(answer: { _ in #"{"ok":false,"error":"unknown command ping"}"# })
        #expect(await refusing.presence() == .answers)
        let absent = RuntimeClient(answer: { _ in throw RuntimeClient.Failure.notRunning(NSError(domain: NSCocoaErrorDomain, code: 4099)) })
        #expect(await absent.presence() == .notRunning)
    }
}
