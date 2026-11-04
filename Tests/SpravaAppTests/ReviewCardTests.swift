import Foundation
import SpravaKit
import SpravaTestSupport
import Testing
@testable import SpravaApp

/// The words on a card's buttons say what they do, for this card, and its file buttons reach only intake files.
@Suite @MainActor struct ReviewCardTests {
    private func card(_ review: CardReview, verified: Bool = true, lines: [String] = [],
                      editable: [BinderActions.Editable] = []) -> BinderActions.Card {
        var c = BinderActions.Card(id: "p", title: "Invented card", actor: "clerk", lines: lines, digest: "d", verified: verified,
                                   intake: nil, folder: nil, notes: [], editable: editable)
        c.review = review
        return c
    }

    private func filing(files: [String], todos: Int = 0, changes: Int = 0) -> CardReview {
        var r = CardReview()
        r.kind = .filing
        r.fromIntake = true
        r.files = files.map { CardReview.File(path: "intake/" + $0, name: $0, kind: $0.hasSuffix(".eml") ? "email" : "attachment") }
        r.todos = (0..<todos).map { .init(index: 10 + $0, title: "Invented \($0)", due: "", priority: "normal", notes: []) }
        r.changes = (0..<changes).map { .init(index: 20 + $0, line: "Invented change", notes: []) }
        return r
    }

    private func editable(_ index: Int, include: Bool = true) -> BinderActions.Editable {
        var e = BinderActions.Editable(index: index, title: "Invented", due: "", priority: "normal", waitingOn: nil)
        e.include = include
        return e
    }

    @Test func theMainButtonSaysWhatThisCardDoes() {
        #expect(card(filing(files: ["a.eml"])).action(editing: nil)?.title == "File this email")
        #expect(card(filing(files: ["a.pdf"])).action(editing: nil)?.title == "File this document")
        #expect(card(filing(files: ["a.eml", "b.pdf", "c.pdf"], todos: 7)).action(editing: nil)?.title == "File 3 documents and add 7 to-dos")
        #expect(card(filing(files: ["a.eml"], todos: 1, changes: 1)).action(editing: nil)?.title == "File this email, add 1 to-do and make 1 change")
        var change = CardReview()
        change.kind = .change
        change.changes = [.init(index: 0, line: "Invented", notes: [])]
        #expect(card(change).action(editing: nil)?.title == "Make this change")
        change.todos = [.init(index: 1, title: "Invented", due: "", priority: "normal", notes: [])]
        #expect(card(change).action(editing: nil)?.title == "Add 1 to-do and make 1 change")
    }

    @Test func theCountsFollowTheItemsLeftOutWhileEditing() {
        let c = card(filing(files: ["a.eml"], todos: 3))
        let title = c.action(editing: [editable(10, include: false), editable(11), editable(12)])?.title
        #expect(title == "File this email and add 2 to-dos")
        #expect(c.action(editing: [editable(10, include: false), editable(11, include: false), editable(12, include: false)])?.title == "File this email")
    }

    @Test func aCardWithNothingLeftCannotBePressed() {
        var r = CardReview()
        r.kind = .change
        r.todos = [.init(index: 0, title: "Invented", due: "", priority: "normal", notes: [])]
        let action = card(r).action(editing: [editable(0, include: false)])
        #expect(action?.enabled == false)
    }

    @Test func aCardTheRuntimeWouldRefuseOffersOnlyTheWayToClearIt() {
        var manual = CardReview()
        manual.kind = .manual
        #expect(card(manual).action(editing: nil) == nil)
        #expect(card(manual).declineTitle == "Reject this card")
        #expect(card(filing(files: ["a.eml"]), verified: false).action(editing: nil) == nil)
        #expect(card(filing(files: ["a.eml"]), verified: false).declineTitle == "Clear it away")
    }

    @Test func aCardSpravaDidNotWriteShowsNoneOfItsClaims() {
        var r = filing(files: ["a.eml"])
        r.heading = "An invented claim"
        r.sender = "Invented sender"
        r.summary = "An invented summary"
        let c = card(r, verified: false, lines: ["Invented line"])
        #expect(c.shown == CardReview())
        #expect(c.heading == "Invented card")
        #expect(c.byline == nil)
    }

    @Test func declineSaysWhatHappensToTheFile() {
        let filed = card(filing(files: ["a.eml"]))
        #expect(filed.declineTitle == "Leave in intake")
        #expect(filed.declineHelp.contains("stays in intake"))
        var other = CardReview()
        other.kind = .change
        #expect(card(other).declineTitle == "Don\u{2019}t do this")
        #expect(card(other).declineHelp == "Nothing in the binder changes.")
    }

    @Test func aBylineIsThePersonAndDateNeverTheProgram() {
        var r = filing(files: ["a.eml"])
        #expect(card(r).byline == nil)
        r.sender = "Invented Landlord"
        r.date = "2026-03-04"
        #expect(card(r).byline == "From Invented Landlord · 2026-03-04")
    }

    @Test func anAssistantsCardSaysSoSinceItsHeadingIsItsOwnWords() {
        var c = card(CardReview())
        c = BinderActions.Card(id: c.id, title: "Invented heading", actor: "brain", lines: [], digest: "d", verified: true,
                               intake: nil, folder: nil, notes: [], editable: [])
        #expect(c.byline == "Suggested by a connected assistant")
    }

    @Test func aManualCardKeepsItsInstructionsAndOffersNoEditItCouldNotApply() {
        var r = filing(files: ["a.pdf"], todos: 1)
        r.kind = .manual
        r.fromIntake = false
        r.heading = "An invented document"
        let c = card(r, editable: [editable(10)])
        #expect(c.heading == "Invented card")
        #expect(c.editTitle == nil)
        #expect(c.action(editing: nil) == nil)
    }

    @Test func anUnverifiedCardsTooltipMakesNoClaimAboutAnIntakeFile() {
        #expect(card(filing(files: ["a.eml"]), verified: false).declineHelp == "Nothing in the binder changes.")
    }

    @Test func onlyAPlainIntakeFileCanBeShown() throws {
        let folder = try temporaryFolder()
        let intake = folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake.appendingPathComponent("mail"), withIntermediateDirectories: true)
        for name in ["a.pdf", "a.pem", "mail/.env", "mail/state.json"] {
            try Data("invented".utf8).write(to: intake.appendingPathComponent(name))
        }
        try Data("invented".utf8).write(to: folder.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(at: intake.appendingPathComponent("link.pdf"), withDestinationURL: folder.appendingPathComponent("outside.txt"))
        try FileManager.default.createDirectory(at: intake.appendingPathComponent("folder.pdf"), withIntermediateDirectories: true)

        #expect(CardReview.fileURL("intake/a.pdf", in: folder)?.lastPathComponent == "a.pdf")
        for path in ["intake/../outside.txt", "outside.txt", "/etc/hosts", "intake/a.pem", "intake/mail/.env", "intake/mail/state.json",
                     "intake/link.pdf", "intake/folder.pdf", "intake/missing.pdf"] {
            #expect(CardReview.fileURL(path, in: folder) == nil, "\(path)")
        }
    }

    @Test func showingAFileRevealsItAndAMissingOneSaysSo() async throws {
        let folder = try temporaryFolder()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        try Data("invented".utf8).write(to: folder.appendingPathComponent("intake/a.pdf"))
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[]}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        var shown: [String] = []
        let actions = BinderActions(client: runtime.client, reveal: { shown.append($0.lastPathComponent) })
        await actions.load(folder, adopted: true)
        await actions.showInFinder(.init(path: "intake/a.pdf", name: "a.pdf", kind: "attachment"), folder.standardizedFileURL)
        #expect(shown == ["a.pdf"])
        #expect(actions.message == nil)
        await actions.showInFinder(.init(path: "intake/gone.pdf", name: "gone.pdf", kind: "attachment"), folder.standardizedFileURL)
        #expect(shown == ["a.pdf"])
        #expect(actions.message?.contains("no longer in intake") == true)
    }

    @Test func theRepliesFactsReachTheCard() async throws {
        let folder = try temporaryFolder()
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        runtime.answers["proposals"] = { _ in
            #"{"ok":true,"proposals":[{"id":"p-1","state":"proposed","title":"t","digest":"d","verified":true,"actor":{"kind":"clerk"},"lines":["l"],"review":{"kind":"filing","heading":"Rent notice","sender":"Invented Landlord","from_intake":true,"summary":"Invented.","files":[{"path":"intake/a.eml","name":"a.eml","kind":"email"}],"todos":[{"index":1,"title":"Pay","due":"2026-04-01","priority":"high","notes":["n"]}],"changes":[{"index":2,"line":"Change","notes":[]}],"warnings":["w"]}}]}"#
        }
        let actions = BinderActions(client: runtime.client)
        await actions.load(folder, adopted: true)
        let review = try #require(actions.cards.first?.review)
        #expect(review.kind == .filing)
        #expect(review.heading == "Rent notice")
        #expect(review.files.first?.label == "Show the email in Finder")
        #expect(review.todos.first?.priority == "high")
        #expect(review.changes.first?.line == "Change")
        #expect(review.warnings == ["w"])
    }
}
