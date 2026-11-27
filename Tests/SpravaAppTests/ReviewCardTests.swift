import Foundation
import SpravaKit
import SpravaTestSupport
import SwiftUI
import AppKit
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

    /// The summary is labelled by who wrote it: Claude when it read the document in the clerk's place (decisions.md D40).
    @Test func theSummarySaysWhoWroteIt() {
        #expect(CardReview(.obj([("summary", .str("An invented notice."))])).summaryLabel == "The clerk\u{2019}s summary")
        #expect(CardReview(.obj([("summary", .str("An invented notice.")), ("summary_by", .str("Claude"))])).summaryLabel == "Claude\u{2019}s summary")
    }

    /// A draft card shows its fields and its button says where it goes; it is approved as it is.
    @Test func aDraftCardSaysPutInDrafts() {
        let v = JSONValue.obj([("kind", .str("draft")), ("draft", .obj([("to", .array([.str("supplier@example.com")])), ("cc", .array([])),
            ("subject", .str("Invoice")), ("body", .str("Invented body.")),
            ("attachments", .array([.obj([("path", .str("documents/notice.txt")), ("name", .str("notice.txt")), ("private", .bool(true))])]))]))])
        let review = CardReview(v)
        #expect(review.draft?.subject == "Invoice" && review.draft?.attachments.first?.isPrivate == true)
        #expect(review.draft?.attachments.first?.file.label == "Show \u{201C}notice.txt\u{201D} in Finder")
        #expect(card(review).action(editing: nil)?.title == "Put in Drafts")
        // A card Sprava did not write shows none of it and offers nothing to carry out.
        #expect(card(review, verified: false).shown.draft == nil && card(review, verified: false).action(editing: nil) == nil)
    }

    /// The draft's fields draw as text, its body in full in a bounded box, its private attachment marked. With
    /// SPRAVA_RENDER_ARTIFACTS_DIR set, it saves what it drew.
    @Test func aDraftCardDraws() throws {
        let draft = CardReview.Draft(to: ["supplier@example.com"], cc: ["office@example.com"], subject: "Invoice for October",
                                     body: "Hello,\n\nCould you send the invoice for October? The notice is attached.\n\nThanks",
                                     attachments: [.init(path: "documents/notice.txt", name: "notice.txt", isPrivate: true),
                                                   .init(path: "documents/plan.txt", name: "plan.txt", isPrivate: false)])
        let host = NSHostingView(rootView: DraftFields(draft: draft, show: { _ in }).padding(12).frame(width: 520))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["SPRAVA_RENDER_ARTIFACTS_DIR"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("draft-card-light.png"))
        }
    }

    /// A rule card shows the rule and its reason whole; its buttons are Accept, Edit and Dismiss (decisions.md D46).
    @Test func aRuleCardSaysAcceptEditDismiss() {
        let v = JSONValue.obj([("kind", .str("rule")), ("rule", .obj([("text", .str("Notices from the building manager go in notices/.")),
            ("reason", .str("You said to remember it.")), ("about", .str("filing"))]))])
        let review = CardReview(v)
        #expect(review.rule == CardReview.Rule(text: "Notices from the building manager go in notices/.", reason: "You said to remember it.", about: "filing"))
        #expect(review.rule?.caption == "Proposed rule for filing")
        let shown = card(review)
        #expect(shown.action(editing: nil)?.title == "Accept" && shown.action(editing: nil)?.enabled == true)
        #expect(shown.editTitle == "Edit" && shown.declineTitle == "Dismiss" && shown.declineHelp.contains("not added"))
        // A card Sprava did not write shows no rule and offers nothing to carry out or change.
        let foreign = card(review, verified: false)
        #expect(foreign.shown.rule == nil && foreign.action(editing: nil) == nil && foreign.editTitle == nil && foreign.declineTitle == "Clear it away")
        // A rule card with no rule the app can read offers nothing to accept.
        #expect(card(CardReview(.obj([("kind", .str("rule"))]))).action(editing: nil) == nil)
    }

    /// A rewrite of the rules shows both sets; it is accepted as shown or dismissed, never edited on the card.
    @Test func aRewriteOfTheRulesSaysReplaceAndOffersNoEdit() throws {
        let v = JSONValue.obj([("kind", .str("rule")), ("rules", .obj([("now", .array([.str("- 2026-10-01: Notices go in notices/."), .str("- 2026-10-09: Building notices go in notices/.")])),
            ("proposed", .array([.str("Notices, the building's too, go in notices/.")])), ("reason", .str("Two rules said the same thing."))]))])
        let review = CardReview(v)
        #expect(review.rule == nil && review.rules?.now.count == 2 && review.rules?.proposed == ["Notices, the building's too, go in notices/."])
        let shown = card(review)
        #expect(shown.action(editing: nil)?.title == "Replace the rules" && shown.editTitle == nil && shown.declineTitle == "Dismiss")
        #expect(shown.declineHelp.contains("stay as they are"))
        #expect(card(review, verified: false).shown.rules == nil && card(review, verified: false).action(editing: nil) == nil)
        // A rewrite with nothing to put in place offers nothing.
        #expect(card(CardReview(.obj([("kind", .str("rule")), ("rules", .obj([("now", .array([])), ("proposed", .array([]))]))]))).action(editing: nil) == nil)

        let host = NSHostingView(rootView: RulesFields(rules: try #require(review.rules)).padding(12).frame(width: 520))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 240)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["SPRAVA_RENDER_ARTIFACTS_DIR"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("rules-rewrite-card-light.png"))
        }
    }

    /// A suggestion card shows its whole text; its buttons are Send to Improvements, Edit and Dismiss (decisions.md D47).
    @Test func aSuggestionCardSaysSendEditDismiss() {
        let v = JSONValue.obj([("kind", .str("suggestion")), ("suggestion", .obj([("title", .str("Import tasks from a hosted board")),
            ("text", .str("What was attempted:\nPulled the board.\n")), ("script", .str("scripts/pull-board.py"))]))])
        let review = CardReview(v)
        #expect(review.suggestion == CardReview.Suggestion(title: "Import tasks from a hosted board", text: "What was attempted:\nPulled the board.\n", script: "scripts/pull-board.py"))
        let shown = card(review)
        #expect(shown.action(editing: nil)?.title == "Send to Improvements" && shown.editTitle == "Edit" && shown.declineTitle == "Dismiss")
        #expect(shown.declineHelp.hasPrefix("Nothing is sent."))
        let foreign = card(review, verified: false)
        #expect(foreign.shown.suggestion == nil && foreign.action(editing: nil) == nil && foreign.editTitle == nil)
        #expect(card(CardReview(.obj([("kind", .str("suggestion"))]))).action(editing: nil) == nil)
    }

    /// Sending uses the suggestion's own command, says where Improvements goes on its first use, and carries the
    /// person's edit exactly as typed, only when they made one.
    @Test func sendingASuggestionCarriesThePersonsEditAndWhereImprovementsGoes() async throws {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[{"id":"p-1","state":"proposed","title":"A suggestion for Sprava","digest":"d1","verified":true,"review":{"kind":"suggestion","suggestion":{"title":"Import tasks","text":"What was attempted:\nPulled the board.\n"}}}]}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        runtime.answers["send_suggestion"] = { _ in #"{"ok":true,"improvements":"/tmp/invented-binders/improvements"}"# }
        let actions = BinderActions(client: runtime.client)
        actions.builtInParent = { (URL(fileURLWithPath: "/tmp/invented-binders"), false) }
        var made: [URL] = []
        actions.builtInUsed = { made.append($0) }
        let folder = URL(fileURLWithPath: "/tmp/invented-kitchen")
        await actions.load(folder, adopted: true)
        let shown = try #require(actions.cards.first)
        // As shown: no text is sent, and the parent always is.
        #expect(actions.suggestionSending(shown).map(\.0) == ["proposal", "digest", "parent", "create_parent"])
        #expect(actions.startEditing(shown) && actions.rules["p-1"] == "What was attempted:\nPulled the board.\n")
        #expect(!actions.draftState.hasChanges)
        #expect(actions.setRule("p-1", "What was attempted:\nPulled the board every Monday.\n"))
        #expect(actions.draftState.hasChanges)
        await actions.approve(shown, folder, reload: {})?.value
        let sent = try #require(runtime.sent.last { $0["command"]?.stringValue == "send_suggestion" })
        #expect(sent["proposal"] == .str("p-1") && sent["digest"] == .str("d1") && sent["text"] == .str("What was attempted:\nPulled the board every Monday.\n"))
        #expect(sent["parent"] == .str("/tmp/invented-binders") && sent["create_parent"] == .bool(false))
        #expect(runtime.sent.allSatisfy { $0["command"]?.stringValue != "approve" })
        #expect(actions.rules["p-1"] == nil && actions.confirmation?.contains("Improvements") == true)
        #expect(made == [URL(fileURLWithPath: "/tmp/invented-binders/improvements", isDirectory: true)])
    }

    /// The suggestion draws as text in a box that scrolls, and as an editor while edited. With SPRAVA_RENDER_ARTIFACTS_DIR set, it saves what it drew.
    @Test func aSuggestionCardDraws() throws {
        let text = "What was attempted:\nPulled the board's open tasks into to-dos.\n\nWhat stood in the way, or keeps being repeated:\nThe same script is run by hand every week.\n\nThe script scripts/pull-board.py, as it was when this was suggested:\n\n" + (1...30).map { "print('line \($0) of the invented script')" }.joined(separator: "\n") + "\n"
        let suggestion = CardReview.Suggestion(title: "Import tasks from a hosted board", text: text, script: "scripts/pull-board.py")
        for (name, edit) in [("suggestion-card-light", nil as Binding<String>?), ("suggestion-card-editing-light", .constant(text))] {
            let host = NSHostingView(rootView: SuggestionFields(suggestion: suggestion, edit: edit).padding(12).frame(width: 520))
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 380)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
            if let directory = ProcessInfo.processInfo.environment["SPRAVA_RENDER_ARTIFACTS_DIR"] {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("\(name).png"))
            }
        }
    }

    /// Accept sends the rule's own command, with the person's edit only when they made one.
    @Test func acceptingARuleSendsItsOwnCommandWithThePersonsEdit() async throws {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[{"id":"p-1","state":"proposed","title":"A rule for filing","digest":"d1","verified":true,"review":{"kind":"rule","rule":{"text":"Notices go in notices/.","reason":"You said so.","about":"filing"}}}]}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        runtime.answers["accept_rule"] = { _ in #"{"ok":true,"digest":"0"}"# }
        let actions = BinderActions(client: runtime.client)
        let folder = URL(fileURLWithPath: "/tmp/invented-kitchen")
        await actions.load(folder, adopted: true)
        let shown = try #require(actions.cards.first)
        // As shown: no edit is sent.
        #expect(actions.ruleAcceptance(shown).map(\.0) == ["proposal", "digest"])
        #expect(!actions.setRule("p-1", "typed before Edit"))
        #expect(actions.startEditing(shown) && actions.rules["p-1"] == "Notices go in notices/.")
        #expect(!actions.startEditing(shown))
        // An edit that changes nothing but the space around it is not an edit.
        #expect(actions.setRule("p-1", " Notices go in notices/. "))
        #expect(actions.ruleAcceptance(shown).count == 2)
        #expect(actions.setRule("p-1", "Building notices go in notices/2026/.\n"))
        await actions.approve(shown, folder, reload: {})?.value
        let sent = try #require(runtime.sent.last { $0["command"]?.stringValue == "accept_rule" })
        #expect(sent["proposal"] == .str("p-1") && sent["digest"] == .str("d1") && sent["rule"] == .str("Building notices go in notices/2026/."))
        #expect(runtime.sent.allSatisfy { $0["command"]?.stringValue != "approve" })
        #expect(actions.rules["p-1"] == nil && actions.confirmation?.contains("Instructions") == true)
    }

    /// The rule and its reason draw as text, and as a field while edited. With SPRAVA_RENDER_ARTIFACTS_DIR set, it saves what it drew.
    @Test func aRuleCardDraws() throws {
        let rule = CardReview.Rule(text: "Notices from the building manager go in notices/, named by the date on the notice.",
                                   reason: "You asked me to remember where the building manager's notices go.", about: "filing")
        for (name, edit) in [("rule-card-light", nil as Binding<String>?), ("rule-card-editing-light", .constant(rule.text))] {
            let host = NSHostingView(rootView: RuleFields(rule: rule, edit: edit).padding(12).frame(width: 520))
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
            if let directory = ProcessInfo.processInfo.environment["SPRAVA_RENDER_ARTIFACTS_DIR"] {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("\(name).png"))
            }
        }
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

    @Test func theLineAboutCopiesSaysNothingWasDeleted() {
        #expect(CardReview.copiesLine(1).hasPrefix("1 file in intake is already filed, as an exact copy or the same email"))
        #expect(CardReview.copiesLine(12).hasPrefix("12 files in intake are already filed, as exact copies or the same emails"))
        #expect(CardReview.copiesLine(12).contains("nothing was deleted"))
    }

    private func reply(_ json: String) throws -> JSONObject {
        try #require(try JSONParser.parse(Data(json.utf8)).value.objectValue)
    }

    @Test func theConfirmationSaysWhatTheApprovalDid() throws {
        let bill = #"{"name":"invoice.pdf","kind":"document"}"#
        let mail = #"{"name":"0199-invented.eml","kind":"email"}"#
        let lines: [(String, String)] = [
            (#"{"applied":3,"todos_added":2,"filed":[\#(bill)]}"#, "Filed \u{201C}invoice.pdf\u{201D} and added 2 to-dos."),
            (#"{"applied":2,"todos_added":1,"filed":[\#(bill)]}"#, "Filed \u{201C}invoice.pdf\u{201D} and added 1 to-do."),
            (#"{"applied":1,"todos_added":1,"filed":[]}"#, "Added 1 to-do."),
            (#"{"applied":4,"todos_added":4,"filed":[]}"#, "Added 4 to-dos."),
            (#"{"applied":1,"todos_added":0,"filed":[\#(bill)]}"#, "Filed \u{201C}invoice.pdf\u{201D}."),
            (#"{"applied":3,"todos_added":0,"filed":[\#(bill),\#(bill),\#(mail)]}"#, "Filed 3 documents."),
            (#"{"applied":2,"todos_added":1,"filed":[\#(mail)]}"#, "Filed the email and added 1 to-do."),
            (#"{"applied":1,"todos_added":0,"filed":[{"name":"","kind":"document"}]}"#, "Filed a document."),
            (#"{"applied":1,"todos_added":0,"filed":[]}"#, "Made 1 change."),
            (#"{"applied":3,"todos_added":0,"filed":[]}"#, "Made 3 changes."),
            (#"{"applied":4,"todos_added":2,"filed":[\#(bill)]}"#, "Filed \u{201C}invoice.pdf\u{201D}, added 2 to-dos and made 1 other change."),
            (#"{}"#, "Done."),
        ]
        for (json, line) in lines { #expect(CardReview.approvedLine(try reply(json)) == line, "\(json)") }
    }

    /// An approved card leaves the page with a word on what it did, counted from the runtime's reply, not the card:
    /// the person may have left out items. A rejection, a refused approval and the next change say nothing of it.
    @Test func anApprovedCardSaysWhatWasDoneUntilTheNextChange() async throws {
        let folder = URL(fileURLWithPath: "/Invented/kitchen-reno", isDirectory: true)
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        runtime.answers["proposals"] = { _ in
            #"{"ok":true,"proposals":[{"id":"p-1","state":"proposed","title":"t","digest":"d1","verified":true,"actor":{"kind":"clerk"},"lines":["l"],"editable":[{"index":1,"title":"Invented call","due":"","priority":"normal"},{"index":2,"title":"Invented visit","due":"","priority":"normal"}],"review":{"kind":"filing","files":[{"path":"intake/quote.pdf","name":"quote.pdf","kind":"document"}],"todos":[{"index":1,"title":"Invented call"},{"index":2,"title":"Invented visit"}]}},{"id":"p-2","state":"proposed","title":"t","digest":"d2","verified":true,"actor":{"kind":"clerk"},"lines":["l"]}]}"#
        }
        let actions = BinderActions(client: runtime.client)
        await actions.load(folder, adopted: true)
        let card = try #require(actions.cards.first)
        let other = try #require(actions.cards.last)

        runtime.answers["approve"] = { _ in #"{"ok":false,"error":"invented refusal"}"# }
        await actions.approve(card, folder, reload: {})?.value
        #expect(actions.confirmation == nil)

        // One of the two to-dos left out: the runtime applied the filing and one to-do.
        actions.startEditing(card)
        actions.setItem(card.id, 2, \.include, false)
        runtime.answers["approve"] = { _ in #"{"ok":true,"applied":2,"todos_added":1,"filed":[{"name":"quote.pdf","kind":"document"}]}"# }
        await actions.approve(card, folder, reload: {})?.value
        #expect(actions.confirmation == "Filed \u{201C}quote.pdf\u{201D} and added 1 to-do.")
        #expect(actions.message == nil)

        runtime.answers["reject"] = { _ in #"{"ok":true}"# }
        await actions.reject(other, folder, reload: {})?.value
        #expect(actions.confirmation == nil)

        // It goes by itself, and with the binder.
        actions.confirmationLifetime = .milliseconds(10)
        actions.confirm("Added 1 to-do.")
        // Waited for with a deadline, not a fixed sleep: on a busy main actor the clearing task may run late (#626).
        let deadline = ContinuousClock.now + .seconds(30)
        while actions.confirmation != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(actions.confirmation == nil)
        actions.confirm("Added 1 to-do.")
        await actions.load(URL(fileURLWithPath: "/Invented/garden-shed", isDirectory: true), adopted: true)
        #expect(actions.confirmation == nil)
    }
}
