import AppKit
import BinderFormat
@testable import SpravaApp
import SpravaKit
import SwiftUI
import Testing

@Suite struct TodoDatesTests {
    // A Tuesday.
    let today = CalendarDate(year: 2031, month: 2, day: 4)!
    func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDate { CalendarDate(year: y, month: m, day: d)! }

    @Test func wordsAPersonTypesBecomeDays() {
        for (typed, expected) in [("today", today), (" Tomorrow ", day(2031, 2, 5)), ("wed", day(2031, 2, 5)), ("friday", day(2031, 2, 7)),
                                  ("tue", day(2031, 2, 11)), ("+3", day(2031, 2, 7)), ("nov 12", day(2031, 11, 12)), ("12 nov", day(2031, 11, 12)),
                                  ("November 12", day(2031, 11, 12)), ("11/12", day(2031, 11, 12)), ("jan 3", day(2032, 1, 3)), ("feb 4", today),
                                  ("2033-03-01", day(2033, 3, 1)), ("3/1/33", day(2033, 3, 1)), ("nov 12, 2032", day(2032, 11, 12))] {
            #expect(TodoDates.parse(typed, today: today) == expected, "\(typed)")
        }
    }

    @Test func whatIsNotADateIsRefusedRatherThanGuessed() {
        for typed in ["", "soon", "feb 31", "13/40", "+", "+x", "2031-02-30", "nov", "12", "fr", "next week", "1/2/3/4"] {
            #expect(TodoDates.parse(typed, today: today) == nil, "\(typed)")
        }
    }

    @Test func aDayReadsShortAndComesBackTheSame() {
        for (date, label) in [(today, "Today"), (day(2031, 2, 5), "Tomorrow"), (day(2031, 11, 6), "Nov 6"), (day(2032, 11, 6), "Nov 6, 2032")] {
            #expect(TodoDates.label(date, today: today) == label)
            #expect(TodoDates.parse(label, today: today) == date)
        }
    }
}

@MainActor
@Suite struct TodoAddTests {
    let folder = URL(fileURLWithPath: "/invented/acme")
    let today = CalendarDate(year: 2031, month: 2, day: 4)!

    @Test func aPastedListAddsOneToDoALineAndUndoTakesThemAllBack() async throws {
        let runtime = StandInRuntime(); var next = 0
        runtime.answers["apply"] = { _ in next += 1; return #"{"ok":true,"op":"0199ffff-0000-7000-8000-00000000000\#(next)"}"# }
        let model = TodoModel(client: runtime.client), target = TodoModel.Target(folder: folder, label: "acme")
        model.draft = "Call the plumber\n\n  Book the van  \nReturn the keys\n"
        model.dueText = "tomorrow"
        await model.add(to: target, today: today, reload: {})
        let titles = runtime.sent.compactMap { $0["args"]?["item"]?["title"]?.stringValue }
        #expect(titles == ["Call the plumber", "Book the van", "Return the keys"])
        #expect(runtime.sent.allSatisfy { $0["args"]?["item"]?["due"] == .str("2031-02-05") })
        #expect(model.draft.isEmpty && model.dueText.isEmpty && model.lastChange?.line == "Added 3 to acme.")
        runtime.answers["undo"] = { _ in #"{"ok":true}"# }
        await model.undo(reload: {})
        let undone = runtime.sent.filter { $0["command"] == .str("undo") }.compactMap { $0["op_id"]?.stringValue }
        #expect(undone == ["0199ffff-0000-7000-8000-000000000003", "0199ffff-0000-7000-8000-000000000002", "0199ffff-0000-7000-8000-000000000001"])
        #expect(model.lastChange == nil)
    }

    @Test func aRefusedLineKeepsTheLinesNotAddedAndUndoStillCoversThoseThatWere() async throws {
        let runtime = StandInRuntime(); var calls = 0
        runtime.answers["apply"] = { _ in
            calls += 1
            if calls == 2 { return #"{"ok":false,"error":"invented refusal"}"# }
            return #"{"ok":true,"op":"0199ffff-0000-7000-8000-000000000001"}"#
        }
        let model = TodoModel(client: runtime.client), target = TodoModel.Target(folder: folder, label: "acme")
        model.draft = "One\nTwo\nThree"
        await model.add(to: target, today: today, reload: {})
        #expect(model.draft == "Two\nThree")
        #expect(model.lastChange?.opIDs.count == 1)
        #expect(model.message?.hasPrefix("Added 1 of 3.") == true)
    }

    @Test func aDateItCannotReadAddsNothingAndKeepsWhatWasTyped() async {
        let runtime = StandInRuntime()
        let model = TodoModel(client: runtime.client)
        model.draft = "Call the plumber"; model.dueText = "someday"
        await model.add(to: .init(folder: folder, label: "acme"), today: today, reload: {})
        #expect(runtime.sent.isEmpty && model.draft == "Call the plumber" && model.dueText == "someday" && model.message != nil)
    }

    @Test func clickingAwayIsNotReturn() async {
        // A draft is only ever sent by `add`; there is no other route from the field to the runtime.
        let runtime = StandInRuntime()
        let model = TodoModel(client: runtime.client)
        model.draft = "Call"
        #expect(runtime.sent.isEmpty && model.draftState.hasChanges)
    }

    func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }
    func settle(_ host: NSView) async {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(25)) }
    }

    /// The one thing the design rests on (2026-11-02 review): after Return, the cursor is back in the row for the next to-do.
    @Test func returnAddsTheToDoAndLeavesTheCursorInTheRow() async throws {
        let runtime = StandInRuntime()
        runtime.answers["apply"] = { _ in #"{"ok":true,"op":"0199ffff-0000-7000-8000-000000000001"}"# }
        let model = TodoModel(client: runtime.client)
        let view = QuickAdd(model: model, targets: [.init(folder: folder, label: "acme")], contexts: [], reload: {})
            .frame(width: 440)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await settle(host)
        let field = try #require(descendants(host, of: NSTextField.self).first { $0.isEditable })
        #expect(window.makeFirstResponder(field))
        for title in ["Call the plumber", "Book the van"] {
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText(title, replacementRange: editor.selectedRange())
            await settle(host)
            #expect(model.draft == title)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            for _ in 0..<40 where !model.draft.isEmpty { await settle(host) }
            #expect(model.draft.isEmpty)
            #expect(field.currentEditor() != nil, "the cursor left the row after \(title)")
        }
        #expect(runtime.sent.compactMap { $0["args"]?["item"]?["title"]?.stringValue } == ["Call the plumber", "Book the van"])
        window.orderOut(nil)
    }
}
