import BinderFormat
import BinderStore
import Brains
import CaptureTestSupport
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// Counts by code, and the suggestion Sprava makes of its own from them (decisions.md D47; plan Track I, step 4): a
/// script started in many turns gets a card. The counts hold no path, host or text. Invented data only.
@Suite(.serialized) struct ClaudeScriptRunsTests {
    struct Fixture {
        let s: PSetup, counts: ImprovementCounts, writer = ClaudeTodoWriter(), database: URL
        init() throws {
            s = try pSetup()
            database = s.support.appendingPathComponent("runtime/improvement-counts.sqlite")
            try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
            counts = try ImprovementCounts(at: database)
            writer.attach(commands: s.commands, queue: DispatchQueue(label: "invented-writer"))
        }
        func script(_ path: String = "scripts/pull-board.py", _ text: String = "print('pull the invented board')\n") throws {
            let url = s.folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func note(_ ran: [String], refused: Int = 0) { ClaudeScriptRuns.note(ran, refusedHosts: refused, folder: s.folder, counts: counts, writer: writer) }
        var cards: [(Proposal, SuggestionCard)] {
            ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" }.compactMap { p in SuggestionCard(p).map { (p, $0) } }
        }
        func req(_ pairs: [(String, JSONValue)]) throws -> JSONValue { try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj(pairs)))).value }
        func shown(_ id: String) throws -> JSONValue {
            try #require(try req([("command", .str("proposals")), ("binder", .string(s.folder.path))])["proposals"]?.arrayValue?.first { $0["id"] == .string(id) })
        }
    }

    @Test func aScriptStartedInFiveTurnsGetsACardOfItsOwn() throws {
        let f = try Fixture()
        try f.script()
        // Named twice in a turn, relative and whole: one count for the turn.
        for _ in 1...4 { f.note(["scripts/pull-board.py", f.s.folder.path + "/scripts/pull-board.py", "ls"]) }
        #expect(f.cards.isEmpty)
        #expect(try f.counts.read(f.s.folder) == [ImprovementCounts.scriptRun: 4, ImprovementCounts.script("scripts/pull-board.py"): 4])
        f.note(["scripts/pull-board.py"])
        let (card, fields) = try #require(f.cards.first)
        #expect(f.cards.count == 1 && fields.script == .init(path: "scripts/pull-board.py", text: "print('pull the invented board')\n"))
        #expect(fields.title == "Build in what the script \u{201C}pull-board.py\u{201D} does" && fields.attempted.contains("5 turns"))
        // Sprava's own card, with no model, and one the person can send: written by Sprava and listed as a suggestion.
        #expect(card.actor["kind"] == .str("clerk") && card.actor["model"] == .str("none"))
        let listed = try f.shown(card.id)
        #expect(listed["verified"] == .bool(true) && listed["review"]?["kind"] == .str("suggestion"))
        // No second card while it waits, nor after it is dismissed, until the 25th turn.
        for _ in 6...24 { f.note(["scripts/pull-board.py"]) }
        #expect(f.cards.map(\.0.id) == [card.id])
        let rejected = try f.req([("command", .str("reject")), ("binder", .string(f.s.folder.path)), ("proposal", .string(card.id)), ("digest", try #require(listed["digest"]))])
        #expect(rejected["ok"] == .bool(true), "\(rejected)")
        f.note(["scripts/pull-board.py"])
        #expect(f.cards.count == 1 && f.cards.first?.0.id != card.id && f.cards.first?.1.attempted.contains("25 turns") == true)
        for _ in 26...60 { f.note(["scripts/pull-board.py"]) }
        #expect(f.cards.count == 1)
    }

    @Test func onlyAScriptTheBinderHoldsIsCountedAndTheCountsHoldNoPath() throws {
        let f = try Fixture()
        try f.script("notes.txt", "not a script\n")
        try f.script("intake/arrived.sh", "echo arrived\n")
        let outside = f.s.support.deletingLastPathComponent().appendingPathComponent("outside-invented.sh")
        try Data("echo outside\n".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: f.s.folder.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.s.folder.appendingPathComponent("scripts/link.sh"), withDestinationURL: outside)
        for _ in 1...6 {
            f.note(["scripts/missing.py", "notes.txt", "intake/arrived.sh", "scripts/link.sh", "scripts/../../outside-invented.sh", outside.path, "/etc/hosts", ".env", ""], refused: 2)
        }
        #expect(try f.counts.read(f.s.folder) == [ImprovementCounts.hostRefused: 12])
        #expect(f.cards.isEmpty)
        // Another binder's counts are its own.
        #expect(try f.counts.read(f.s.folder.appendingPathComponent("elsewhere")).isEmpty)
        // What is kept names no script and no binder.
        try f.script("scripts/pull-invented-board.py")
        f.note(["scripts/pull-invented-board.py"])
        #expect(try f.counts.read(f.s.folder)[ImprovementCounts.scriptRun] == 1)
        for file in try FileManager.default.contentsOfDirectory(at: f.database.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix("improvement-counts") {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data("pull-invented-board".utf8)) == nil && bytes.range(of: Data(f.s.folder.lastPathComponent.utf8)) == nil)
        }
    }

    /// A script too long for a card, or a waiting list that is full, makes no card and loses no count.
    @Test func aCardThatCannotBeMadeIsLeftOut() throws {
        let f = try Fixture()
        try f.script("scripts/long.py", String(repeating: "print('invented')\n", count: 4_000))
        for _ in 1...6 { f.note(["scripts/long.py"]) }
        #expect(f.cards.isEmpty)
        #expect(try f.counts.read(f.s.folder).isEmpty)
        // A writer that is not attached: the count is kept, no card is made, nothing throws.
        try f.script()
        let detached = ClaudeTodoWriter()
        for _ in 1...5 { ClaudeScriptRuns.note(["scripts/pull-board.py"], refusedHosts: 0, folder: f.s.folder, counts: f.counts, writer: detached) }
        #expect(f.cards.isEmpty)
        #expect(try f.counts.read(f.s.folder)[ImprovementCounts.script("scripts/pull-board.py")] == 5)
    }

    /// Through the conversation: a turn's scripts are counted once at its end, whether it replied or failed.
    @Test func aTurnsScriptsAreCountedOnceAtItsEnd() async throws {
        let c = try await ClaudeTodoToolsTests.Conversation()
        let url = c.s.folder.appendingPathComponent("scripts/pull-board.py")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("print('pull the invented board')\n".utf8).write(to: url)
        c.engine.lock.withLock { c.engine.ran = ["scripts/pull-board.py"] }
        _ = try await c.turn { _ in }
        #expect(try c.runtime.improvementCounts.read(c.s.folder)[ImprovementCounts.scriptRun] == 1)
        c.engine.lock.withLock { c.engine.failure = ClaudeReadOnlyTurn.Failure.deadline }
        _ = try await c.turn { _ in }
        #expect(try c.runtime.improvementCounts.read(c.s.folder)[ImprovementCounts.scriptRun] == 2)
        c.engine.lock.withLock { c.engine.failure = nil; c.engine.ran = [] }
        _ = try await c.turn { _ in }
        #expect(try c.runtime.improvementCounts.read(c.s.folder)[ImprovementCounts.scriptRun] == 2)
    }
}
