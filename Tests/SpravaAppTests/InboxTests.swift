import Foundation
import Services
@testable import SpravaApp
import SpravaKit
import Testing

/// The Inbox's note, written by the app as a capture event (the one app-side write besides background-off and
/// the recent order), against a stand-in runtime. Temporary folders and invented notes only.
@MainActor
@Suite struct InboxTests {
    @Test func textTypedWhileTheNoteIsSavedIsKept() async throws {
        let support = try temporaryFolder()
        let deviceID = try DeviceID.load(support: support)   // made by the runtime at its first start
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
        let events = try FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("Captures/\(deviceID)").path)
            .filter { $0.hasSuffix(".json") }
        #expect(events.count == 2)
    }

    @Test func aDraftEmptiedAndBegunAgainTakesTheNewStart() {
        let inbox = InboxModel(client: StandInRuntime().client, support: URL(fileURLWithPath: "/Invented/support"))
        let monday = Date(timeIntervalSince1970: 1_791_360_000)
        let tuesday = monday.addingTimeInterval(86_400)
        inbox.draftChanged("Call the", now: monday)
        inbox.draftChanged("Call the notary", now: monday.addingTimeInterval(5))
        #expect(inbox.startedTyping == monday)
        inbox.draftChanged("", now: monday.addingTimeInterval(10))
        #expect(inbox.startedTyping == nil)
        inbox.draftChanged("Book the movers tomorrow", now: tuesday)
        #expect(inbox.startedTyping == tuesday)
        // A draft cleared down to blank space is empty too, as saving reads it.
        inbox.draftChanged(" \n ", now: tuesday.addingTimeInterval(5))
        #expect(inbox.startedTyping == nil)
    }

    @Test func aNoteTooLargeForTheRuntimeStaysInTheEditor() async throws {
        let support = try temporaryFolder()
        let deviceID = try DeviceID.load(support: support)
        let runtime = StandInRuntime()
        runtime.answers["capture_notice"] = { _ in #"{"ok":true}"# }
        let inbox = InboxModel(client: runtime.client, support: support)
        inbox.draft = String(repeating: "Invented line to pay the deposit\n", count: InboxModel.largestNote / 32)
        let saved = await inbox.saveDraft(binderName: nil)
        #expect(!saved)
        #expect(inbox.draft.count > InboxModel.largestNote / 2)
        #expect(inbox.message?.contains("too long") == true)
        #expect(!runtime.sent.contains { $0["command"]?.stringValue == "capture_notice" })
        let folder = support.appendingPathComponent("Captures/\(deviceID)").path
        let events = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".json") }
        #expect(events.isEmpty)
    }

    @Test func untrustedCardsAndReadingsAreKeptBoundedAsTheyAreRead() async throws {
        let runtime = StandInRuntime()
        let long = String(repeating: "invented words ", count: 200)
        let many = (0..<200).map { JSONValue.string("Invented line \($0)") }
        var cards: [JSONValue] = (0..<300).map { i in
            .obj([("id", .string("card-\(i)")), ("title", .str("Invented note")), ("lines", .array([])), ("notes", .array([]))])
        }
        cards[0] = .obj([("id", .str("card-0")), ("title", .string(long)), ("lines", .array([.string(long)])),
                         ("notes", .array(many)), ("not_filed", .array([.string(long)] + many)), ("producer", .string(long))])
        let reply = JSONWriter.compact(.obj([("ok", .bool(true)), ("cards", .array(cards))]))
        let readings = JSONWriter.compact(.obj([("ok", .bool(true)), ("readings", .array((0..<120).map { i in
            .obj([("id", .string("reading-\(i)")), ("title", .string(long)), ("summary", .string(long)), ("reasons", .array(many))])
        }))]))
        runtime.answers["unfiled"] = { _ in reply }
        runtime.answers["readings"] = { _ in readings }
        let inbox = InboxModel(client: runtime.client, support: URL(fileURLWithPath: "/Invented/support"))
        await inbox.load()
        #expect(inbox.cardCount == 300 && inbox.cards.count == Shown.items)
        #expect(inbox.readingCount == 120 && inbox.readings.count == Shown.items)
        let first = try #require(inbox.cards.first)
        let drawn = [first.title, first.producer] + first.lines.lines + first.notes.lines + first.notFiled.lines
        #expect(drawn.allSatisfy { $0.count <= Shown.characters + 1 })
        #expect(first.notes.lines.count == Shown.limit && first.notes.more == 200 - Shown.limit)
        #expect(first.notFiled.more == 201 - Shown.limit)
        let reading = try #require(inbox.readings.first)
        #expect(reading.title.count <= Shown.characters + 1 && (reading.summary?.count ?? 0) <= Shown.characters + 1)
        #expect(reading.reasons.lines.count == Shown.limit)
        // A short line is drawn whole.
        #expect(Shown.preview("Invented short line") == "Invented short line")
        // One character with thousands of combining marks is cut too.
        let marked = "e" + String(repeating: "\u{0301}", count: 10_000)
        #expect(marked.count == 1)
        #expect(Shown.preview(marked).unicodeScalars.count <= Shown.characters + 1)
    }

    @Test func bindersThatShareANameAndAParentFolderNameAreToldApart() {
        let first = URL(fileURLWithPath: "/Invented/home/archive/taxes/tax-2026", isDirectory: true)
        let second = URL(fileURLWithPath: "/Invented/work/archive/taxes/tax-2026", isDirectory: true)
        let a = InboxView.label(name: "tax-2026", folder: first, sharesName: true)
        let b = InboxView.label(name: "tax-2026", folder: second, sharesName: true)
        #expect(a != b)
        #expect(InboxView.label(name: "tax-2026", folder: first, sharesName: false) == "tax-2026")
    }

    @Test func aCaptureWithManyLinesIsDrawnBounded() {
        let lines = (0..<50_000).map { "Invented line \($0)" }
        let shown = Shown(lines)
        #expect(shown.lines.count == Shown.limit && shown.more == 50_000 - Shown.limit)
        #expect(shown.lines.first == "Invented line 0")
        let few = Shown(["Invented one", "Invented two"])
        #expect(few.lines.count == 2 && few.more == 0)
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

    @Test func theAppNeverMakesTheDeviceID() async throws {
        let support = try temporaryFolder()
        let inbox = InboxModel(client: StandInRuntime().client, support: support)
        inbox.draft = "Renew the parking permit"
        #expect(!(await inbox.saveDraft(binderName: nil)))
        #expect(inbox.message?.contains("has not started on this Mac yet") == true)
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("device-id").path))
        #expect(inbox.draft == "Renew the parking permit")
    }
}
