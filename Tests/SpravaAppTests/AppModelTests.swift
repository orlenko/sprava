import Foundation
import Shelf
@testable import SpravaApp
import SpravaKit
import SpravaTestSupport
import Testing

// The screens' models, against a stand-in runtime: no test talks to a real runtime over XPC, and every folder is a
// temporary one with invented content.

/// Answers requests by command name with a JSON text, or refuses the ones it has no answer for, and records them.
@MainActor
final class StandInRuntime {
    var answers: [String: @MainActor (JSONValue) async -> String] = [:]
    var sent: [JSONValue] = []

    // Holds the stand-in strongly: a test may keep only the client.
    lazy var client = RuntimeClient(answer: { [self] text in
        let request = try JSONParser.parse(text).value
        sent.append(request)
        guard let name = request["command"]?.stringValue, let answer = answers[name] else {
            return #"{"ok":false,"error":"Sprava's background part is not running."}"#
        }
        return await answer(request)
    })
}

func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-app-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
@Suite struct BinderPageTests {
    let kitchen = URL(fileURLWithPath: "/tmp/invented/kitchen-reno", isDirectory: true)
    let garden = URL(fileURLWithPath: "/tmp/invented/garden-shed", isDirectory: true)

    @Test func anotherBindersSettingsAreNeverSavedIntoThisOne() async {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"Kitchen renovation quotes","filing":true}"# }
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[]}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: true)
        #expect(actions.settingsLoaded && actions.description == "Kitchen renovation quotes" && actions.filing)

        // The garden binder's settings cannot be read: the fields are cleared and stay locked.
        runtime.answers["binder_settings"] = nil
        await actions.load(garden, adopted: true)
        #expect(!actions.settingsLoaded && actions.description.isEmpty && !actions.filing)
        actions.description = "typed before the settings arrived"
        actions.saveSettings(garden)
        // A save that went ahead would be busy at once; this one was refused before anything was sent.
        #expect(!actions.busy)
        let writes = runtime.sent.filter { $0["command"]?.stringValue == "binder_settings" && $0["description"] != nil }
        #expect(writes.isEmpty)
    }

    @Test func aReplyForTheBinderLeftBehindIsDropped() async {
        let runtime = StandInRuntime()
        let actions = BinderActions(client: runtime.client)
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[]}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        runtime.answers["binder_settings"] = { [garden, kitchenPath = kitchen.standardizedFileURL.path] request in
            guard request["binder"]?.stringValue == kitchenPath else {
                return #"{"ok":true,"description":"Garden shed build","filing":false}"#
            }
            // The person opens the garden binder while the kitchen's settings are on their way.
            await actions.load(garden, adopted: true)
            return #"{"ok":true,"description":"Kitchen renovation quotes","filing":true}"#
        }
        await actions.load(kitchen, adopted: true)
        #expect(actions.serves(garden))
        #expect(actions.description == "Garden shed build" && !actions.filing && actions.settingsLoaded)
    }

    @Test func aRefusedApprovalKeepsTheEdits() async throws {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["proposals"] = { _ in
            #"{"ok":true,"proposals":[{"id":"p-1","state":"proposed","title":"Add 1 item","digest":"d1","verified":true,"actor":{"kind":"clerk"},"lines":["Call the tiler"],"editable":[{"index":0,"title":"Call the tiler","due":"2026-10-20","priority":"normal"}]}]}"#
        }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: true)
        let card = try #require(actions.cards.first)
        actions.editing[card.id] = card.editable
        actions.editing[card.id]![0].due = "2026-10-32"

        runtime.answers["approve"] = { _ in #"{"ok":false,"error":"due: not a calendar date"}"# }
        await actions.approve(card, kitchen, reload: {}).value
        #expect(actions.editing[card.id]?.first?.due == "2026-10-32")
        #expect(actions.message == "due: not a calendar date")

        actions.editing[card.id]![0].due = "2026-10-31"
        runtime.answers["approve"] = { _ in #"{"ok":true}"# }
        await actions.approve(card, kitchen, reload: {}).value
        #expect(actions.editing[card.id] == nil)
        let sent = runtime.sent.last { $0["command"]?.stringValue == "approve" }
        let edits = try #require(sent?["edits"]?.arrayValue)
        #expect(edits.first?["due"]?.stringValue == "2026-10-31")
    }
}

@MainActor
@Suite struct InboxTests {
    @Test func textTypedWhileTheNoteIsSavedIsKept() async throws {
        let support = try temporaryFolder()
        let runtime = StandInRuntime()
        let inbox = InboxModel(client: runtime.client, support: support)
        inbox.draft = "Call the notary by Friday"
        runtime.answers["capture_notice"] = { _ in
            inbox.draft += "\nBook the movers"
            return #"{"ok":true}"#
        }
        var saved = await inbox.saveDraft(binderName: nil)
        #expect(saved)
        #expect(inbox.draft == "Call the notary by Friday\nBook the movers")

        runtime.answers["capture_notice"] = { _ in #"{"ok":true}"# }
        saved = await inbox.saveDraft(binderName: nil)
        #expect(saved)
        #expect(inbox.draft.isEmpty)
        let deviceID = try String(contentsOf: support.appendingPathComponent("device-id"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let events = try FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("Captures/\(deviceID)").path)
            .filter { $0.hasSuffix(".json") }
        #expect(events.count == 2)
    }

    @Test func aNoteThatCannotBeSavedSaysWhyInASentence() async throws {
        let support = try temporaryFolder()
        try Data("not an id\n".utf8).write(to: support.appendingPathComponent("device-id"))
        let inbox = InboxModel(client: StandInRuntime().client, support: support)
        inbox.draft = "Renew the parking permit"
        let saved = await inbox.saveDraft(binderName: nil)
        #expect(!saved)
        #expect(inbox.message == "The note was not saved: \(support.appendingPathComponent("device-id").path) exists but is not a device id; it was left as it is")
        #expect(inbox.draft == "Renew the parking permit")
    }
}

@MainActor
@Suite struct ShelfModelTests {
    @Test func aFolderThatCannotBeAddedSaysSoAfterTheRefresh() throws {
        let support = try temporaryFolder()
        try Data(#"{"schemaVersion":1,"folders":[]}"#.utf8).write(to: support.appendingPathComponent("shelf.json"))
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "kitchen-reno")
        let model = ShelfModel(support: support)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: support.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path) }
        model.add([binder])
        #expect(model.note?.hasPrefix("Could not add kitchen-reno: ") == true)
        #expect(model.rows.isEmpty)
    }

    @Test func aFolderThatCannotBeRemovedSaysSoAfterTheRefresh() throws {
        let support = try temporaryFolder()
        let binder = try makeTeka(fixture: "sprava-v0", folderName: "garden-shed")
        let model = ShelfModel(support: support)
        model.add([binder])
        let row = try #require(model.rows.first)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: support.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path) }
        model.removeFromShelf(row)
        #expect(model.note?.hasPrefix("Could not remove \(row.name): ") == true)
        #expect(model.rows.count == 1)
    }
}

@MainActor
@Suite struct OffloadAndBrainsTests {
    @Test func aRefusedOffloadIsShownOnTheBindersPage() async {
        let backup = BackupModel(client: StandInRuntime().client)
        let binder = URL(fileURLWithPath: "/tmp/invented/kitchen-reno", isDirectory: true)
        let took = await backup.send("offload", binder: binder, confirm: true)
        #expect(!took)
        #expect(backup.binderMessages[binder.standardizedFileURL] == "Not started: Sprava's background part is not running.")
    }

    @Test func theShownCommandKeepsAPathWithSpacesInOneArgument() {
        let args = ["claude", "mcp", "add", "--scope", "user", "--env", "SPRAVA_CLIENT_TOKEN=abc123", "sprava", "--",
                    "/Applications/Personal Apps/Sprava.app/Contents/MacOS/sprava-mcp", "--client", "claude-code-1"]
        #expect(BrainsModel.shellLine(args) == "claude mcp add --scope user --env SPRAVA_CLIENT_TOKEN=abc123 sprava -- "
            + "'/Applications/Personal Apps/Sprava.app/Contents/MacOS/sprava-mcp' --client claude-code-1")
        #expect(BrainsModel.shellLine(["it's", ""]) == #"'it'\''s' ''"#)
    }
}
