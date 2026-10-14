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

    /// Codex loads `AGENTS.override.md` ahead of `AGENTS.md`, so a filed document must never take that name.
    @Test func agentsOverrideIsAManual() {
        #expect(!DocumentPaths.isSafe("AGENTS.override.md"))
        #expect(!DocumentPaths.isSafe("documents/agents.OVERRIDE.md"))
        #expect(!DocumentPaths.isSafe("documents/AGENTS.override.md", forFiling: false))
        #expect(DocumentPaths.safeName("AGENTS.override.md") == "_AGENTS.override.md")
    }
}
