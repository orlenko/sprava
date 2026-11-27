@testable import BinderStore
import BinderFormat
import Foundation
import SpravaKit
import Testing

/// The card that carries a suggestion for Sprava (decisions.md D47). Invented text only.
@Suite struct SuggestionCardTests {
    let actor = JSONObject([(key: "kind", value: .str("brain"))])
    let script = SuggestionCard.Script(path: "scripts/pull-board.py", text: "print('pull the invented board')\n")

    func card(_ script: SuggestionCard.Script? = nil) -> SuggestionCard {
        SuggestionCard(title: " Import tasks from a hosted board ", attempted: "Pulled the board's open tasks into to-dos.\n",
                       obstacle: "The same script is run by hand every week.", script: script)
    }

    @Test func theCardHoldsTheTextAndItsOpHoldsNone() throws {
        let made = try card(script).proposal(actor: actor)
        let read = try #require(SuggestionCard(made))
        #expect(read == SuggestionCard(title: "Import tasks from a hosted board", attempted: "Pulled the board's open tasks into to-dos.",
                                       obstacle: "The same script is run by hand every week.", script: script))
        #expect(read.note == """
        What was attempted:
        Pulled the board's open tasks into to-dos.

        What stood in the way, or keeps being repeated:
        The same script is run by hand every week.

        The script scripts/pull-board.py, as it was when this was suggested:

        print('pull the invented board')

        """)
        #expect(try #require(SuggestionCard(try card().proposal(actor: actor))).note.hasSuffix("The same script is run by hand every week.\n"))
        #expect(made.ops.count == 1 && made.ops[0]["args"]?["entry"]?["action"] == .str("Sent a suggestion to Improvements"))
        // Another op riding along, or another title, makes it no suggestion card.
        var raw = made.raw
        raw.set("ops", .array([.object(made.ops[0]), .object(made.ops[0])]))
        #expect(SuggestionCard(Proposal(raw: raw)) == nil)
        raw = made.raw; raw.set("title", .str("Something else"))
        #expect(SuggestionCard(Proposal(raw: raw)) == nil)
        #expect(RuleCard(made) == nil && RulesRewrite(made) == nil)
    }

    @Test func whatCannotBeReadWholeIsRefused() {
        func refused(_ card: SuggestionCard) -> Bool { (try? card.proposal(actor: actor)) == nil }
        #expect(!refused(card(script)))
        var c = card(); c.title = ""; #expect(refused(c))
        c = card(); c.title = "Two\nlines"; #expect(refused(c))
        c = card(); c.title = String(repeating: "t", count: SuggestionCard.maxTitle + 1); #expect(refused(c))
        c = card(); c.attempted = "  "; #expect(refused(c))
        c = card(); c.obstacle = String(repeating: "o", count: SuggestionCard.maxPart + 1); #expect(refused(c))
        c = card(); c.obstacle = "Hidden \u{202E}text"; #expect(refused(c))
        // A script outside the binder, a key file, one too large, one that is not plain text.
        for path in ["../elsewhere/run.sh", "/tmp/run.sh", "scripts/.env", "scripts/token-board.json", ".sprava/ops.ndjson", "intake/run.sh",
                     "scripts", "documents/notice.txt", "catalog.json", "tools/~run.sh", "scripts//run.sh", ""] {
            #expect(!SuggestionCard.isScriptPath(path) && refused(card(.init(path: path, text: "x"))), "\(path)")
        }
        for path in ["scripts/pull-board.py", "scripts/run", "tools/export.sh", "Scripts/Pull Board.PY", "sync.rb"] { #expect(SuggestionCard.isScriptPath(path), "\(path)") }
        #expect(refused(card(.init(path: "scripts/run.sh", text: String(repeating: "x", count: SuggestionCard.maxScript + 1)))))
        #expect(refused(card(.init(path: "scripts/run.sh", text: "bell \u{07}"))))
        // The person's edit is held to the same rules.
        #expect(SuggestionCard.problem(note: "A plain edit.\n\tWith a tab.") == nil)
        #expect(SuggestionCard.problem(note: " \n") != nil && SuggestionCard.problem(note: "bell \u{07}") != nil)
        #expect(SuggestionCard.problem(note: String(repeating: "n", count: SuggestionCard.maxNote + 1)) != nil)
    }

    /// Step 3: text that looks like a key is noticed, so the card can warn. The samples are put together here so that
    /// no line of this file looks like one.
    @Test func whatLooksLikeAKeyIsNoticed() {
        let filler = String(repeating: "a1B2", count: 10)
        let keys = ["token = \"" + filler + "\"", "API_KEY=" + filler, "password: " + filler, "Authorization: Bearer " + filler,
                    "-----BEGIN " + "RSA PRIVATE KEY-----", "sk" + "-" + filler, "gh" + "p_" + filler, "AK" + "IA" + String(repeating: "A", count: 16),
                    "xox" + "b-" + filler, "ey" + "J" + filler + "." + filler + "." + filler]
        for key in keys { #expect(SuggestionCard.looksLikeItHoldsAKey("curl the board\n" + key + "\n"), "\(key.prefix(12))") }
        for plain in ["print('pull the invented board')", "token = os.environ['BOARD_TOKEN']", "The password is asked for each time.",
                      "import secrets", "key = row['id']", "risk-assessment-of-the-invented-roof-2026"] {
            #expect(!SuggestionCard.looksLikeItHoldsAKey(plain), "\(plain)")
        }
    }
}
