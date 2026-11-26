import BinderFormat
import BinderStore
import Brains
import CaptureTestSupport
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// A suggestion for Sprava, from the conversation tool to the Improvements binder (decisions.md D47; plan Track I).
/// The session writes a card in its own binder; only the person's approval carries the text over. Invented data only.
@Suite(.serialized) struct SuggestionCardCommandTests {
    typealias Turn = ClaudeTodoToolsTests.Turn

    func req(_ c: Commands, _ pairs: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(pairs)))).value
    }
    func suggest(_ turn: Turn, title: String = "Import tasks from a hosted board", script: String? = nil) -> (refused: Bool, content: JSONValue) {
        var args: [(String, JSONValue)] = [("title", .string(title)), ("attempted", .str("Pulled the board's open tasks into to-dos.")),
                                           ("obstacle", .str("The same script is run by hand every week."))]
        if let script { args.append(("script", .string(script))) }
        let answer = turn.call("suggest_improvement", args)
        return (answer.refused, answer.content)
    }
    func cards(_ s: PSetup) -> [(Proposal, SuggestionCard)] {
        ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" }.compactMap { p in SuggestionCard(p).map { (p, $0) } }
    }
    func shown(_ s: PSetup, _ id: String) throws -> JSONValue {
        try #require(try req(s.commands, [("command", .str("proposals")), ("binder", .string(s.folder.path))])["proposals"]?.arrayValue?.first { $0["id"] == .string(id) })
    }
    func parent(_ s: PSetup) -> URL { s.support.deletingLastPathComponent().appendingPathComponent("binders") }
    func send(_ s: PSetup, _ id: String, text: JSONValue? = nil) throws -> JSONValue {
        var fields: [(String, JSONValue)] = [("command", .str("send_suggestion")), ("binder", .string(s.folder.path)), ("proposal", .string(id)),
                                             ("digest", try shown(s, id)["digest"]!), ("parent", .string(parent(s).path)), ("create_parent", .bool(true))]
        if let text { fields.append(("text", text)) }
        return try req(s.commands, fields)
    }
    func script(_ s: PSetup, _ path: String = "scripts/pull-board.py", _ text: String = "print('pull the invented board')\n") throws {
        let url = s.folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // Done when (plan Track I): a suggestion with a script is approved after an edit and appears in Improvements.
    @Test func aSuggestionWithAScriptIsSentAfterAnEditAndAppearsInImprovements() throws {
        let s = try pSetup(), turn = try Turn(s)
        try script(s)
        let ops = turn.ops.count
        let answer = suggest(turn, script: "scripts/pull-board.py")
        #expect(!answer.refused, "\(answer.content)")
        let (card, fields) = try #require(cards(s).first)
        #expect(fields.script == .init(path: "scripts/pull-board.py", text: "print('pull the invented board')\n"))
        // Nothing left the binder in the turn: no op, no Improvements binder, nothing on the Shelf.
        #expect(turn.ops.count == ops && !FileManager.default.fileExists(atPath: parent(s).path))
        // What the app is given to show: the whole text.
        let review = try #require(try shown(s, card.id)["review"])
        #expect(review["kind"] == .str("suggestion") && review["suggestion"]?["title"] == .str("Import tasks from a hosted board"))
        #expect(review["suggestion"]?["text"] == .string(fields.note) && review["suggestion"]?["script"] == .str("scripts/pull-board.py"))
        #expect(review["warnings"]?.arrayValue?.count == 1)
        // The ordinary approve never sends it.
        let approved = try req(s.commands, [("command", .str("approve")), ("binder", .string(s.folder.path)), ("proposal", .string(card.id)), ("digest", try shown(s, card.id)["digest"]!)])
        #expect(approved["ok"] == .bool(false) && cards(s).count == 1)

        let edited = fields.note.replacingOccurrences(of: "every week", with: "every Monday")
        let digest = try shown(s, card.id)["digest"]!
        let sent = try send(s, card.id, text: .string(edited))
        #expect(sent["ok"] == .bool(true), "\(sent)")
        let improvements = URL(fileURLWithPath: try #require(sent["improvements"]?.stringValue))
        #expect(try BuiltInBinder.kind(of: improvements, support: s.support) == .improvements)
        let items = Teka.read(improvements).catalog?["open_items"]?.arrayValue ?? []
        #expect(items.count == 1 && items.first?["title"] == .str("Import tasks from a hosted board") && items.first?["details"] == .string(edited))
        #expect(Teka.read(improvements).catalog?["meta"]?["disclosure"] == .str("none"))
        // The source binder keeps a log entry with none of the text, and the card is applied.
        #expect(cards(s).isEmpty)
        let log = Teka.read(s.folder).catalog?["processing_log"]?.arrayValue ?? []
        #expect(log.last?["action"] == .str("Sent a suggestion to Improvements"))
        #expect(!JSONWriter.compact(log.last ?? .null).contains("board"))
        // Sent once: a second send of the applied card adds nothing.
        let again = try req(s.commands, [("command", .str("send_suggestion")), ("binder", .string(s.folder.path)), ("proposal", .string(card.id)),
                                         ("digest", digest), ("parent", .string(parent(s).path))])
        #expect(again["ok"] == .bool(false))
        #expect(Teka.read(improvements).catalog?["open_items"]?.arrayValue?.count == 1)
    }

    // An approval tried again after the to-do was written (the card not yet marked) adds no second to-do.
    @Test func aSendTriedAgainAddsNoSecondToDo() throws {
        let s = try pSetup(), turn = try Turn(s)
        #expect(!suggest(turn).refused)
        let (card, fields) = try #require(cards(s).first)
        let made = try req(s.commands, [("command", .str("improvements_binder")), ("parent", .string(parent(s).path)), ("create_parent", .bool(true))])
        let improvements = URL(fileURLWithPath: try #require(made["binder"]?.stringValue))
        let added = try req(s.commands, [("command", .str("apply")), ("binder", .string(improvements.path)), ("op", .str("add_item")),
            ("args", .obj([("item", .obj([("id", .str("$new:1")), ("title", .string(fields.title)), ("status", .str("open")), ("priority", .str("normal")),
                                          ("no_deadline", .bool(true)), ("details", .string(fields.note)), ("suggestion_card", .string(card.id))]))]))])
        #expect(added["ok"] == .bool(true), "\(added)")
        #expect(try send(s, card.id)["ok"] == .bool(true))
        #expect(Teka.read(improvements).catalog?["open_items"]?.arrayValue?.count == 1 && cards(s).isEmpty)
        #expect(Teka.read(improvements).catalog?["open_items"]?.arrayValue?.first?["details"] == .string(fields.note))
    }

    // The same, when the person changed the text before trying again: the to-do holds what they approved last.
    @Test func aSendTriedAgainWithAnEditWritesTheEdit() throws {
        let s = try pSetup(), turn = try Turn(s)
        #expect(!suggest(turn).refused)
        let (card, fields) = try #require(cards(s).first)
        let made = try req(s.commands, [("command", .str("improvements_binder")), ("parent", .string(parent(s).path)), ("create_parent", .bool(true))])
        let improvements = URL(fileURLWithPath: try #require(made["binder"]?.stringValue))
        let added = try req(s.commands, [("command", .str("apply")), ("binder", .string(improvements.path)), ("op", .str("add_item")),
            ("args", .obj([("item", .obj([("id", .str("$new:1")), ("title", .string(fields.title)), ("status", .str("open")), ("priority", .str("normal")),
                                          ("no_deadline", .bool(true)), ("details", .string(fields.note)), ("suggestion_card", .string(card.id))]))]))])
        #expect(added["ok"] == .bool(true), "\(added)")
        let edited = fields.note + "\nIt should also skip tasks already closed.\n"
        let sent = try send(s, card.id, text: .string(edited))
        #expect(sent["ok"] == .bool(true), "\(sent)")
        let items = Teka.read(improvements).catalog?["open_items"]?.arrayValue ?? []
        #expect(items.count == 1 && items.first?["details"] == .string(edited) && cards(s).isEmpty)
    }

    @Test func onlyACardSpravaWroteIsSentAndAnEditIsHeldToTheRules() throws {
        let s = try pSetup(), turn = try Turn(s)
        #expect(!suggest(turn).refused)
        let (card, _) = try #require(cards(s).first)
        #expect(try send(s, card.id, text: .int(3))["ok"] == .bool(false))
        #expect(try send(s, card.id, text: .str("  "))["ok"] == .bool(false))
        #expect(try send(s, card.id, text: .str("bell \u{07}"))["ok"] == .bool(false))
        // A card with a suggestion that another writer saved and Sprava trusted, but its tool never recorded.
        let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("claude"))])
        let foreign = try SuggestionCard(title: "Another", attempted: "Something.", obstacle: "Something else.").proposal(actor: actor)
        try ProposalStore.save(foreign, in: s.folder)
        try s.commands.trustProposals([foreign.id], in: s.folder)
        #expect(try send(s, foreign.id)["ok"] == .bool(false))
        #expect(cards(s).count == 2 && !FileManager.default.fileExists(atPath: parent(s).path))
    }

    @Test func aScriptIsReadOnlyFromInsideTheBinderAndNeverAKeyFile() throws {
        let s = try pSetup()
        try script(s, "scripts/.env", "BOARD=invented\n")
        try script(s, "scripts/big.py", String(repeating: "#", count: SuggestionCard.maxScript + 1))
        let outside = s.support.deletingLastPathComponent().appendingPathComponent("outside.py")
        try Data("print('outside the binder')\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: s.folder.appendingPathComponent("scripts/link.py"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: s.folder.appendingPathComponent("linked"), withDestinationURL: outside.deletingLastPathComponent())
        try script(s, "documents/notice.txt", "An invented notice.\n")
        for path in ["scripts/.env", "scripts/big.py", "scripts/link.py", "linked/outside.py", "../outside.py", outside.path, "scripts/missing.py",
                     "documents/notice.txt", "catalog.json"] {
            #expect(suggest(try Turn(s), script: path).refused, "\(path)")
        }
        #expect(cards(s).isEmpty)
    }

    // Step 3: the card warns when the script holds what looks like a key.
    @Test func theCardWarnsWhenTheScriptLooksLikeItHoldsAKey() throws {
        let s = try pSetup(), turn = try Turn(s)
        try script(s, "scripts/pull-board.py", "token = \"" + String(repeating: "a1B2", count: 10) + "\"\nprint('pull')\n")
        #expect(!suggest(turn, script: "scripts/pull-board.py").refused)
        let (card, _) = try #require(cards(s).first)
        let warnings = try shown(s, card.id)["review"]?["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(warnings.count == 2 && warnings.first?.contains("looks like a key") == true)
    }

    @Test func aTurnSuggestsFewAndNeverTheSameTwice() throws {
        let s = try pSetup(), turn = try Turn(s)
        #expect(!suggest(turn).refused)
        #expect(suggest(turn).refused)
        #expect(!suggest(turn, title: "Export to-dos to a calendar").refused)
        #expect(suggest(turn, title: "A third in one turn").refused)
        #expect(suggest(try Turn(s), title: "Two\nlines").refused)
        #expect(cards(s).count == 2)
        let session = ClaudeConversationPolicy.session(todos: true)
        #expect(session.contains("suggest_improvement") && !ClaudeConversationPolicy.session(todos: false).contains("suggest_improvement"))
    }
}
