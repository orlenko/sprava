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

    func export(_ s: PSetup, _ path: String) throws -> JSONValue {
        try req(s.commands, [("command", .str("export_suggestions")), ("path", .string(path))])
    }

    // Done when (plan Track I): the exported file holds exactly the approved text.
    @Test func theExportedFileHoldsExactlyTheApprovedText() throws {
        let s = try pSetup(), turn = try Turn(s)
        try script(s, "scripts/pull-board.py", "print('pull')\necho ```fenced``` and ````more````\n")
        let out = s.support.deletingLastPathComponent().appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = out.appendingPathComponent("suggestions.md")
        // Before any suggestion was sent there is nothing to export, and no Improvements binder is made for it.
        let none = try export(s, file.path)
        #expect(none["ok"] == .bool(false) && none["error"]?.stringValue?.contains("no suggestions yet") == true)
        #expect(!FileManager.default.fileExists(atPath: parent(s).path) && !FileManager.default.fileExists(atPath: file.path))

        #expect(!suggest(turn, script: "scripts/pull-board.py").refused)
        #expect(!suggest(turn, title: "Export to-dos to a calendar").refused)
        let made = cards(s)
        let first = try #require(made.first { $0.1.script != nil }), second = try #require(made.first { $0.1.script == nil })
        let edited = first.1.note.replacingOccurrences(of: "every week", with: "every Monday")
        let sent = try send(s, first.0.id, text: .string(edited))
        #expect(sent["ok"] == .bool(true), "\(sent)")
        #expect(try send(s, second.0.id)["ok"] == .bool(true))
        let improvements = URL(fileURLWithPath: try #require(sent["improvements"]?.stringValue))
        // A to-do the person added to Improvements by hand is theirs, not a suggestion: it is never exported.
        let own = try req(s.commands, [("command", .str("apply")), ("binder", .string(improvements.path)), ("op", .str("add_item")),
            ("args", .obj([("item", .obj([("id", .str("$new:1")), ("title", .str("A private note to self")), ("status", .str("open")),
                                          ("priority", .str("normal")), ("no_deadline", .bool(true)), ("details", .str("Not for export."))]))]))])
        #expect(own["ok"] == .bool(true), "\(own)")
        let before = try Data(contentsOf: improvements.appendingPathComponent("catalog.json"))

        let exported = try export(s, file.path)
        #expect(exported["ok"] == .bool(true) && exported["count"] == .int(2), "\(exported)")
        let text = try String(contentsOf: file, encoding: .utf8)
        // Each has its code above its text: the same at every export, from the card's id alone.
        let code = SuggestionExport.code(card: first.0.id)
        #expect(code.hasPrefix("S-") && code.count == 12 && code != SuggestionExport.code(card: second.0.id))
        #expect(text.hasPrefix("# Suggestions for Sprava\n\nExported \(CalendarDate.today()). 2 suggestions.\n\n## Import tasks from a hosted board\n\nCode: `\(code)`\n\n`````text\n"))
        // Exactly the approved text, between a fence longer than any run of backticks in it.
        #expect(text.contains("`````text\n" + edited + "\n`````\n"))
        #expect(text.contains("## Export to-dos to a calendar\n\nCode: `\(SuggestionExport.code(card: second.0.id))`\n\n```text\n" + second.1.note + "\n```\n"))
        // The file is the person's alone, new or replaced.
        #expect(try mode(file) == 0o600)
        #expect(!text.contains("private note") && !text.contains("Not for export"))
        // Nothing in the binder changed, and a second export replaces the file.
        #expect(try Data(contentsOf: improvements.appendingPathComponent("catalog.json")) == before)
        #expect(try export(s, file.path)["ok"] == .bool(true))
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
        // Over a file the person had opened to others, and over one they had not: owner-only either way.
        for before in [0o644, 0o600] as [mode_t] {
            chmod(file.path, before)
            #expect(try export(s, file.path)["ok"] == .bool(true))
            #expect(try mode(file) == 0o600)
        }
    }

    func mode(_ file: URL) throws -> mode_t {
        var info = stat()
        try #require(lstat(file.path, &info) == 0)
        return info.st_mode & 0o7777
    }

    /// A text that ends in a line break and the same text without it export differently, and each comes back exactly.
    @Test func theExportKeepsWhetherTheTextEndsInALineBreak() throws {
        func exported(_ text: String) -> String { SuggestionExport.markdown([(title: "An invented title", text: text, code: "S-0000000000")], on: CalendarDate.today()) }
        /// The text of the one block: after the line that opens it, up to the line break before the line that closes it.
        func block(_ markdown: String) throws -> String {
            let lines = markdown.components(separatedBy: "\n")
            let open = try #require(lines.firstIndex { $0.hasPrefix("```") && $0.hasSuffix("text") })
            let fence = String(lines[open].dropLast(4))
            let close = try #require(lines.lastIndex(of: fence))
            return lines[(open + 1)..<close].joined(separator: "\n")
        }
        let texts = ["print('pull')", "print('pull')\n", "print('pull')\n\n", "", "\n", "a ``` b\n````", "trailing spaces  \ne\u{301}"]
        for text in texts { #expect(try block(exported(text)) == text, "\(text.debugDescription)") }
        #expect(Set(texts.map(exported)).count == texts.count)
    }

    @Test func exportWritesOnlyAMarkdownFileOutsideTheBinders() throws {
        let s = try pSetup(), turn = try Turn(s)
        #expect(!suggest(turn).refused)
        let (card, _) = try #require(cards(s).first)
        let improvements = URL(fileURLWithPath: try #require(try send(s, card.id)["improvements"]?.stringValue))
        let out = s.support.deletingLastPathComponent().appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: out.appendingPathComponent("taken.md"), withIntermediateDirectories: true)
        // A binder Sprava was never shown, with a folder inside it.
        let stray = out.appendingPathComponent("stray-binder/papers", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: out.appendingPathComponent("stray-binder/catalog.json"))
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("link.md"), withDestinationURL: improvements.appendingPathComponent("catalog.json"))
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("into-binder"), withDestinationURL: improvements)
        let catalog = try Data(contentsOf: improvements.appendingPathComponent("catalog.json"))
        for path in ["suggestions.md", out.appendingPathComponent("suggestions.txt").path, out.appendingPathComponent("missing/suggestions.md").path,
                     out.appendingPathComponent("taken.md").path, out.appendingPathComponent("link.md").path,
                     out.appendingPathComponent("into-binder/suggestions.md").path,
                     improvements.appendingPathComponent("suggestions.md").path, s.folder.appendingPathComponent("suggestions.md").path,
                     s.support.appendingPathComponent("suggestions.md").path, stray.appendingPathComponent("suggestions.md").path] {
            let refused = try export(s, path)
            #expect(refused["ok"] == .bool(false), "\(path)")
        }
        #expect(try req(s.commands, [("command", .str("export_suggestions"))])["ok"] == .bool(false))
        #expect(try Data(contentsOf: improvements.appendingPathComponent("catalog.json")) == catalog)
        #expect(!FileManager.default.fileExists(atPath: improvements.appendingPathComponent("suggestions.md").path))
        #expect(try export(s, out.appendingPathComponent("suggestions.md").path)["count"] == .int(1))
    }

    func waiting(_ c: Commands, in folder: URL) throws -> [JSONValue] {
        (try req(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? []).filter { $0["state"] == .str("proposed") }
    }

    // Plan Track I, step 6: a suggestion a release built is closed with the release's note, on a card the person approves.
    @Test func aBuiltSuggestionGetsAClosingCardThePersonApproves() throws {
        let s = try pSetup(), turn = try Turn(s)
        // Before any suggestion was sent: nothing to close, and no Improvements binder is made for it.
        let note = "The hosted board importer does this now: Settings, Importers."
        #expect(try s.commands.closeBuiltSuggestions(now: Date(), built: [.init(code: "S-0000000000", note: note)])["cards"] == .int(0))
        #expect(!FileManager.default.fileExists(atPath: parent(s).path))
        #expect(!suggest(turn).refused)
        #expect(!suggest(turn, title: "Export to-dos to a calendar").refused)
        var improvements: URL?
        var codes: [String: String] = [:]
        for (card, fields) in cards(s) {
            improvements = URL(fileURLWithPath: try #require(try send(s, card.id)["improvements"]?.stringValue))
            codes[fields.title] = SuggestionExport.code(card: card.id)
        }
        let folder = try #require(improvements)
        // This build built nothing, as the command the app sends finds; then a build that built one of the two.
        #expect(try req(s.commands, [("command", .str("close_built_suggestions"))])["cards"] == .int(0))
        let built: [BuiltSuggestions.Built] = [.init(code: try #require(codes["Import tasks from a hosted board"]), note: note), .init(code: "S-0000000000", note: "Another")]
        #expect(try s.commands.closeBuiltSuggestions(now: Date(), built: built)["cards"] == .int(1))
        let card = try #require(try waiting(s.commands, in: folder).first)
        #expect(card["title"] == .str("Built into Sprava: Import tasks from a hosted board") && card["verified"] == .bool(true))
        // Nothing is closed until the person approves, and a second start writes no second card.
        #expect(Teka.read(folder).catalog?["open_items"]?.arrayValue?.count == 2)
        #expect(try s.commands.closeBuiltSuggestions(now: Date(), built: built)["cards"] == .int(0))
        #expect(try waiting(s.commands, in: folder).count == 1)
        let approved = try req(s.commands, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", try #require(card["id"])), ("digest", try #require(card["digest"]))])
        #expect(approved["ok"] == .bool(true), "\(approved)")
        let catalog = try #require(Teka.read(folder).catalog)
        #expect(catalog["open_items"]?.arrayValue?.map { $0["title"] } == [.str("Export to-dos to a calendar")])
        let closed = try #require(catalog["processing_log"]?.arrayValue?.last { $0["action"] == .str("done") })
        #expect(closed["title"] == .str("Import tasks from a hosted board") && closed["note"] == .string(note))
        #expect(try s.commands.closeBuiltSuggestions(now: Date(), built: built)["cards"] == .int(0))
    }

    @Test func aClosingCardThePersonRejectedDoesNotComeBack() throws {
        let s = try pSetup(), turn = try Turn(s)
        #expect(!suggest(turn).refused)
        let (made, _) = try #require(cards(s).first)
        let folder = URL(fileURLWithPath: try #require(try send(s, made.id)["improvements"]?.stringValue))
        let built: [BuiltSuggestions.Built] = [.init(code: SuggestionExport.code(card: made.id), note: "Built in.")]
        #expect(try s.commands.closeBuiltSuggestions(now: Date(), built: built)["cards"] == .int(1))
        let card = try #require(try waiting(s.commands, in: folder).first)
        let rejected = try req(s.commands, [("command", .str("reject")), ("binder", .string(folder.path)), ("proposal", try #require(card["id"])), ("digest", try #require(card["digest"]))])
        #expect(rejected["ok"] == .bool(true), "\(rejected)")
        #expect(try s.commands.closeBuiltSuggestions(now: Date(), built: built)["cards"] == .int(0))
        #expect(try waiting(s.commands, in: folder).isEmpty && Teka.read(folder).catalog?["open_items"]?.arrayValue?.count == 1)
    }
}
