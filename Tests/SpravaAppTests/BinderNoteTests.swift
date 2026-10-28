import BinderFormat
import Foundation
import Services
import Shelf
@testable import SpravaApp
import SpravaKit
import Testing

/// The note box at the top of a binder's page, against a stand-in runtime: a note names the binder it was typed in
/// whatever the filing list says, each binder keeps its own draft, and a note that cannot be filed here says where
/// it went. Temporary folders, invented binders and notes only.
@MainActor
@Suite struct BinderNoteTests {
    let acme = URL(fileURLWithPath: "/Invented/acme", isDirectory: true)
    let globex = URL(fileURLWithPath: "/Invented/globex", isDirectory: true)

    func row(_ folder: URL) -> ShelfRow { ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder)) }

    /// The capture events the app wrote, as the runtime would read them.
    func events(_ support: URL, _ deviceID: String) throws -> [JSONValue] {
        let folder = support.appendingPathComponent("Captures/\(deviceID)")
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
            .map { try JSONParser.parse(Data(contentsOf: folder.appendingPathComponent($0))).value }
    }

    @Test func aNoteTypedInABinderNamesThatBinderWhateverTheFilingList() async throws {
        let support = try temporaryFolder()
        let deviceID = try DeviceID.load(support: support)
        let runtime = StandInRuntime()
        runtime.answers["capture_notice"] = { _ in #"{"ok":true}"# }
        // The binder is off the filing list: the note box never asks.
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"Invented acme paperwork","filing":false}"# }
        let note = BinderNote(client: runtime.client, support: support, readRoute: { _, _ in .here })
        note.show(acme)
        note.text = "Renew the acme permit\nCall the acme landlord"
        note.changed(note.text)
        #expect(await note.add(row(acme), sharesName: false))
        #expect(note.text.isEmpty && note.startedTyping == nil)
        #expect(note.message?.hasPrefix("Added.") == true)
        let written = try events(support, deviceID)
        #expect(written.count == 1)
        #expect(written.first?["binder_hint"] == .str("acme"))
        #expect(written.first?["sensitivity"] == .str("unmarked"))
        #expect(written.first?["text"] == .str("Renew the acme permit\nCall the acme landlord"))
        // The runtime is told first, so it trusts the binder named; nothing else is asked.
        #expect(runtime.sent.compactMap { $0["command"]?.stringValue } == ["capture_notice"])
        #expect(runtime.sent.first?["binder"] == .str(acme.standardizedFileURL.path))
    }

    @Test func eachBinderKeepsItsOwnDraft() async throws {
        let support = try temporaryFolder()
        _ = try DeviceID.load(support: support)
        let runtime = StandInRuntime()
        runtime.answers["capture_notice"] = { _ in #"{"ok":true}"# }
        let note = BinderNote(client: runtime.client, support: support, readRoute: { _, _ in .here })
        note.show(acme)
        note.text = "Renew the acme permit"
        note.show(globex)
        #expect(note.text.isEmpty)
        // A note is only ever sent for the binder shown, never with another binder's words.
        #expect(await note.add(row(acme), sharesName: false) == false)
        #expect(runtime.sent.isEmpty)
        note.show(acme)
        #expect(note.text == "Renew the acme permit")
    }

    @Test func aDraftOutlivesTheBinderPage() {
        let note = BinderNote(client: StandInRuntime().client, support: URL(fileURLWithPath: "/Invented/support"))
        note.show(acme)
        note.text = "Renew the acme permit"
        // The page is built again after a visit to the Inbox or Health: it draws the model the window keeps.
        let today = CalendarDate.today()
        let page = NowView(row: row(acme), today: today, page: NowPage(items: [], log: [], today: today, timeZone: .current),
                           reload: {}, note: note, editor: ItemEditor())
        #expect(page.note === note)
        note.show(acme)
        #expect(page.note.text == "Renew the acme permit")
    }

    @Test func privateBinderNotesKeepSensitivityThroughEveryInboxFallback() async throws {
        for (sharesName, acknowledged) in [(false, true), (true, true), (false, false)] {
            let support = try temporaryFolder()
            let deviceID = try DeviceID.load(support: support)
            let runtime = StandInRuntime()
            runtime.running = acknowledged
            runtime.answers["capture_notice"] = { _ in #"{"ok":true}"# }
            let note = BinderNote(client: runtime.client, support: support, readRoute: { _, _ in .privateBinder })
            note.show(acme)
            note.text = "Keep the invented permit private"
            #expect(await note.add(row(acme), sharesName: sharesName))
            let written = try events(support, deviceID)
            let event = try #require(written.first)
            #expect(written.count == 1)
            #expect(event["sensitivity"] == .str("private"))
            #expect(event["binder_hint"] == nil)
            #expect(event["text"] == .str("Keep the invented permit private"))
        }
    }

    @Test func anUnavailablePrivacyReadKeepsTheNotePrivateWithoutAHint() async throws {
        for sharesName in [false, true] {
            let support = try temporaryFolder()
            let deviceID = try DeviceID.load(support: support)
            let runtime = StandInRuntime()
            runtime.answers["capture_notice"] = { _ in #"{"ok":true}"# }
            let note = BinderNote(client: runtime.client, support: support, readRoute: { _, _ in .here },
                                  deadline: { _, expire in expire() })
            note.show(acme)
            note.text = "Keep the invented permit safe"
            #expect(await note.add(row(acme), sharesName: sharesName))
            let written = try events(support, deviceID)
            let event = try #require(written.first)
            #expect(written.count == 1)
            #expect(event["sensitivity"] == .str("private"))
            #expect(event["binder_hint"] == nil)
            #expect(event["text"] == .str("Keep the invented permit safe"))
            #expect(note.message?.contains("Inbox") == true)
            #expect(note.text.isEmpty)
        }
    }

    @Test func privateAndSharedNameBindersKeepTheExplicitFolderWithoutANameHint() async throws {
        let support = try temporaryFolder()
        let deviceID = try DeviceID.load(support: support)
        let runtime = StandInRuntime()
        runtime.answers["capture_notice"] = { _ in #"{"ok":true}"# }
        // A name alone is ambiguous; the authenticated notice keeps the selected folder.
        let shared = BinderNote(client: runtime.client, support: support, readRoute: { _, _ in .here })
        shared.show(acme)
        shared.text = "Renew the acme permit"
        #expect(await shared.add(row(acme), sharesName: true))
        #expect(shared.message?.hasPrefix("Added.") == true)
        // Selecting the private binder on its own page is an explicit destination choice.
        let secret = BinderNote(client: runtime.client, support: support, readRoute: { _, _ in .privateBinder })
        secret.show(acme)
        secret.text = "Sign the acme papers"
        #expect(await secret.add(row(acme), sharesName: false))
        #expect(secret.message?.hasPrefix("Added.") == true)
        let written = try events(support, deviceID)
        #expect(written.count == 2 && written.allSatisfy { $0["binder_hint"] == nil })
        #expect(runtime.sent.count == 2 && runtime.sent.allSatisfy { $0["binder"] == .str(acme.standardizedFileURL.path) })
    }
}
