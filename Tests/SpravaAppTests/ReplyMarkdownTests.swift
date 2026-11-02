import Foundation
@testable import SpravaApp
import SwiftUI
import Testing

@Suite struct ReplyMarkdownTests {
    private func links(_ text: AttributedString) -> [URL] { text.runs.compactMap(\.link) }
    private func words(_ text: AttributedString) -> String { String(text.characters) }

    @Test func theFeaturesRepliesUseBecomeBlocks() {
        let reply = """
        # Invented title

        First line
        second line

        - one
          - nested
        * two
        1. first
          goes on
        12) twelfth
        ---
        ```
        - not a list
        ```
        """
        #expect(ReplyMarkdown.blocks(reply) == [
            .heading(level: 1, text: "Invented title"),
            .paragraph("First line\nsecond line"),
            .item(marker: "\u{2022}", depth: 0, text: "one"),
            .item(marker: "\u{2022}", depth: 1, text: "nested"),
            .item(marker: "\u{2022}", depth: 0, text: "two"),
            .item(marker: "1.", depth: 0, text: "first\ngoes on"),
            .item(marker: "12.", depth: 0, text: "twelfth"),
            .rule,
            .code("- not a list"),
        ])
    }

    @Test func oddLinesStayWordsAndNothingIsLost() {
        #expect(ReplyMarkdown.blocks("#no space\n-no space\n2026. was a year") == [.paragraph("#no space\n-no space\n2026. was a year")])
        #expect(ReplyMarkdown.blocks("```\nnever closed") == [.code("never closed")])
        #expect(ReplyMarkdown.blocks("") == [])
        #expect(words(ReplyMarkdown.inline("Write to <name> about 3 < 4", folder: nil)) == "Write to <name> about 3 < 4")
        #expect(words(ReplyMarkdown.inline("**bold** and *italic* and `code`", folder: nil)) == "bold and italic and code")
    }

    @Test func onlyTheWebAndMailCanBeClicked() {
        for hostile in ["[x](file:///etc/hosts)", "[x](javascript:alert(1))", "[x](sprava-binder-file:/etc/hosts)",
                        "[x](x-apple.systempreferences:com.apple.preference)", "[x](ssh://example.com)", "[x](/etc/hosts)", "[x](../../etc/hosts)"] {
            #expect(links(ReplyMarkdown.inline(hostile, folder: nil)).isEmpty, "\(hostile)")
        }
        #expect(links(ReplyMarkdown.inline("[x](https://example.com/a)", folder: nil)) == [URL(string: "https://example.com/a")!])
        #expect(links(ReplyMarkdown.inline("[x](mailto:person@example.com)", folder: nil)) == [URL(string: "mailto:person@example.com")!])
        #expect(links(ReplyMarkdown.inline("see https://example.com/a now", folder: nil)) == [URL(string: "https://example.com/a")!])
        #expect(links(ReplyMarkdown.inline("`https://example.com/a`", folder: nil)).isEmpty)
    }

    @Test func aLinkShowingOtherWordsNamesItsHost() {
        #expect(words(ReplyMarkdown.inline("[Your bank](https://other.example.net/login)", folder: nil)) == "Your bank (other.example.net)")
        #expect(words(ReplyMarkdown.inline("[Your bank](https://bank.example.com@other.example.net/)", folder: nil)) == "Your bank (other.example.net)")
        #expect(words(ReplyMarkdown.inline("[https://example.com/a](https://example.com/a)", folder: nil)) == "https://example.com/a")
        #expect(words(ReplyMarkdown.inline("[example.com](https://example.com/a)", folder: nil)) == "example.com")
    }

    @Test func anImageIsNeverALinkOrALoad() {
        let text = ReplyMarkdown.inline("![invented alt](https://example.com/pixel.png)", folder: nil)
        #expect(links(text).isEmpty)
        #expect(!words(text).contains("example.com"))
    }

    @Test func aFileLinkNamesOnlyAFileInsideTheBinder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("binder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("case"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("case/invented note.md"))
        try Data("x".utf8).write(to: root.appendingPathComponent("outside.md"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.md"), withDestinationURL: root.appendingPathComponent("outside.md"))

        let linked = links(ReplyMarkdown.inline("[note](case/invented%20note.md)", folder: folder))
        #expect(linked.first?.scheme == ReplyMarkdown.fileScheme)
        #expect(links(ReplyMarkdown.inline("`case/invented note.md`", folder: folder)).first?.scheme == ReplyMarkdown.fileScheme)
        for outside in ["[x](../outside.md)", "[x](escape.md)", "[x](case/missing.md)", "`../outside.md`", "`missing.md`"] {
            #expect(links(ReplyMarkdown.inline(outside, folder: folder)).isEmpty, "\(outside)")
        }
        // A link to a file that has gone by the time of the click does nothing.
        let gone = try #require(linked.first)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("case/invented note.md"))
        #expect(ReplyMarkdown.binderFile(gone.path, folder: folder) == nil)
    }
}
