@testable import BinderFormat
import Darwin
import Foundation
import Testing

@Suite(.serialized) struct IntakeTests {
    @Test func pathRules() {
        #expect(DocumentPaths.isSafe("documents/letter.pdf"))
        #expect(DocumentPaths.isSafe("correspondence/2026/note.txt"))
        #expect(!DocumentPaths.isSafe("catalog.json"))
        #expect(!DocumentPaths.isSafe("Catalog.JSON"))
        #expect(!DocumentPaths.isSafe("Intake/x.pdf"))
        #expect(!DocumentPaths.isSafe("chapters/x.pdf"))
        #expect(DocumentPaths.isSafe("chapters/x.pdf", forFiling: false))
        #expect(!DocumentPaths.isSafe("documents/AGENTS.md"))
        #expect(!DocumentPaths.isSafe(".sprava/x"))
        #expect(!DocumentPaths.isSafe("documents//x"))
        #expect(!DocumentPaths.isSafe("/abs/x"))
        #expect(!DocumentPaths.isSafe("documents/invoice\u{202E}fdp.command"))
        #expect(!DocumentPaths.isSafe("documents/cafe\u{0301}.pdf"))   // not NFC
        #expect(DocumentPaths.isIntake("intake/a.pdf"))
        #expect(!DocumentPaths.isIntake("intake/mail/.env"))
        #expect(!DocumentPaths.isIntake("documents/a.pdf"))
        #expect(DocumentPaths.safeName(".hidden\u{202E}name.pdf") == "hidden_name.pdf")
        #expect(DocumentPaths.safeName("CLAUDE.md") == "_CLAUDE.md")
    }

    /// An email can name its attachment with a million combining marks, a million U+0F73 (each splits into two marks),
    /// or a million dots, and a model can write such a path. None is normalized, so nothing stalls, and such a name is
    /// held as a key file's, before and after cleaning, whatever it hides in its middle.
    @Test func anEnormousNameIsNeverNormalizedAndNeverRead() {
        let enormous = ["a" + String(repeating: "\u{0301}\u{0316}", count: 500_000) + ".pdf",
                        "a" + String(repeating: "\u{0F73}", count: 1_000_000) + ".pdf",
                        String(repeating: ".", count: 2_000_000) + "x.pdf",
                        String(repeating: "a", count: 1_000) + ".keychain" + String(repeating: "b", count: 100) + ".txt"]
        // Plain truths only: Swift Testing records an expectation's values, and recording a million marks is slow too.
        var wrong: [Int] = []
        let took = ContinuousClock().measure {
            for (i, name) in enormous.enumerated() {
                let held = DocumentPaths.isKeyFile(name) && DocumentPaths.isKeyFile("/mail/" + name)
                    && DocumentPaths.safeName(name) == DocumentPaths.tooLongName && DocumentPaths.isKeyFile(DocumentPaths.safeName(name))
                let refused = !DocumentPaths.isSafe("documents/" + name) && !DocumentPaths.isIntake("intake/mail/" + name)
                    && !DocumentPaths.isSafe(String(repeating: "d/", count: 2_100) + "a")
                if !(held && refused && DocumentPaths.fold(name).unicodeScalars.count == name.unicodeScalars.count) { wrong.append(i) }
            }
        }
        #expect(wrong.isEmpty)
        #expect(took < .seconds(3))
        // A name at the limit is judged and cleaned as before.
        let long = String(repeating: "\u{00E9}", count: DocumentPaths.longestName - 4) + ".pdf"
        #expect(DocumentPaths.safeName(long) == long && !DocumentPaths.isKeyFile(long))
        #expect(DocumentPaths.safeName("...~.hidden.pdf") == "hidden.pdf")
    }

    /// Codex loads `AGENTS.override.md` ahead of `AGENTS.md`, so a filed document must never take that name.
    @Test func agentsOverrideIsAManual() {
        #expect(!DocumentPaths.isSafe("AGENTS.override.md"))
        #expect(!DocumentPaths.isSafe("documents/agents.OVERRIDE.md"))
        #expect(!DocumentPaths.isSafe("documents/AGENTS.override.md", forFiling: false))
        #expect(DocumentPaths.safeName("AGENTS.override.md") == "_AGENTS.override.md")
    }
}
