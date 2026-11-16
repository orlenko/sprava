@testable import BinderFormat
import Foundation
import Testing

/// The person's part of a binder's AGENTS.md (docs/binder-instructions.md §2). Every text is invented.
@Suite struct BinderInstructionsTests {
    func binder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-instructions-\(UUID().uuidString)/household-example")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func noMarkersIsAllThePersons() throws {
        let text = "Bills go in bills/<provider>.\n"
        let parsed = try BinderInstructions.parse(text).get()
        #expect(parsed.section == "")
        #expect(parsed.text == text)
    }

    @Test func sectionIsSplitOutWhereverItIs() throws {
        let section = "<!-- sprava:begin -->\nPropose through Sprava.\n  <!-- sprava:end -->  \n"
        let parsed = try BinderInstructions.parse("Before.\n" + section + "After.\n").get()
        #expect(parsed.section == section)
        #expect(parsed.text == "Before.\nAfter.\n")
    }

    @Test func savingKeepsTheSectionAndReadsBackTheSameText() throws {
        let found = BinderInstructions(exists: true, section: "<!-- sprava:begin -->\nx\n<!-- sprava:end -->", text: "old")
        let written = found.contents(with: "Insurance letters go in insurance.\n")
        #expect(written == "<!-- sprava:begin -->\nx\n<!-- sprava:end -->\nInsurance letters go in insurance.\n")
        let back = try BinderInstructions.parse(written).get()
        #expect(back.text == "Insurance letters go in insurance.\n")
        #expect(back.section == "<!-- sprava:begin -->\nx\n<!-- sprava:end -->\n")
        #expect(BinderInstructions(exists: false, section: "", text: "").contents(with: "a") == "a")
    }

    @Test func crlfKeepsItsBytes() throws {
        let text = "One.\r\n<!-- sprava:begin -->\r\nx\r\n<!-- sprava:end -->\r\nTwo.\r\n"
        let parsed = try BinderInstructions.parse(text).get()
        #expect(parsed.text == "One.\r\nTwo.\r\n")
        #expect(parsed.section == "<!-- sprava:begin -->\r\nx\r\n<!-- sprava:end -->\r\n")
    }

    @Test func markersOutOfOrderAreAmbiguous() {
        for text in ["<!-- sprava:begin -->\nno end\n",
                     "<!-- sprava:begin -->\n<!-- sprava:begin -->\n<!-- sprava:end -->\n",
                     "<!-- sprava:end -->\nstray\n",
                     "<!-- sprava:begin -->\n<!-- sprava:end -->\n<!-- sprava:end -->\n",
                     "<!-- sprava:begin -->\n<!-- sprava:end -->\n<!-- sprava:begin -->\n<!-- sprava:end -->\n"] {
            #expect(throws: BinderInstructions.Problem.ambiguousMarkers) { try BinderInstructions.parse(text).get() }
        }
    }

    @Test func aMarkerInProseIsText() throws {
        let text = "Sprava writes <!-- sprava:begin --> above its own part.\n"
        #expect(try BinderInstructions.parse(text).get().text == text)
    }

    @Test func readsTheFileOrNothing() throws {
        let folder = try binder()
        let missing = try BinderInstructions.read(folder).get()
        #expect(!missing.exists && missing.text == "" && missing.section == "")
        try Data("Mission: one flat's paperwork.\n".utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        let read = try BinderInstructions.read(folder).get()
        #expect(read.exists && read.text == "Mission: one flat's paperwork.\n")
        #expect(read.digest == BinderInstructions.digest("Mission: one flat's paperwork.\n"))
    }

    @Test func refusesALinkLargeFilesAndOtherBytes() throws {
        let folder = try binder()
        let elsewhere = folder.deletingLastPathComponent().appendingPathComponent("elsewhere.md")
        try Data("not the binder's".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("AGENTS.md"), withDestinationURL: elsewhere)
        guard case .failure(.refused) = BinderInstructions.read(folder) else { Issue.record("a link was followed"); return }

        try FileManager.default.removeItem(at: folder.appendingPathComponent("AGENTS.md"))
        try Data(repeating: 0x61, count: BinderInstructions.fileLimit + 1).write(to: folder.appendingPathComponent("AGENTS.md"))
        guard case .failure(.refused) = BinderInstructions.read(folder) else { Issue.record("a large file was read"); return }

        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: folder.appendingPathComponent("AGENTS.md"))
        #expect(throws: BinderInstructions.Problem.notText) { try BinderInstructions.read(folder).get() }
    }

    @Test func guidanceIsTrimmedAndCut() {
        #expect(BinderInstructions(exists: true, section: "", text: " \n\n ").guidance == nil)
        #expect(BinderInstructions(exists: true, section: "", text: "\nOne rule.\n").guidance?.text == "One rule.")
        let long = BinderInstructions(exists: true, section: "", text: String(repeating: "a", count: BinderInstructions.maxCharacters + 5))
        #expect(long.guidance?.text.count == BinderInstructions.maxCharacters)
        #expect(long.guidance?.cut == true)
    }

    @Test func onlyTheAcceptedTextIsFollowed() throws {
        let folder = try binder()
        let text = "Receipts go in receipts.\n"
        try Data(text.utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        #expect(try BinderInstructions.read(folder).get().isAccepted == false)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".sprava"), withIntermediateDirectories: true)
        let record = folder.appendingPathComponent(BinderInstructions.recordPath)
        let digest = BinderInstructions.digest(text)
        try Data(#"{"accepted": "\#(digest)", "undo_after": "\#(digest)"}"#.utf8).write(to: record)
        let read = try BinderInstructions.read(folder).get()
        #expect(read.isAccepted && read.canUndo)
        // Edited outside the app: shown, not followed, and no Undo of the last save.
        try Data("Receipts go in receipts and shoeboxes.\n".utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        let edited = try BinderInstructions.read(folder).get()
        #expect(!edited.isAccepted && !edited.canUndo)
        // A record that is not Sprava's shape accepts nothing.
        try Data(#"{"accepted": "yes"}"#.utf8).write(to: record)
        #expect(BinderInstructions.record(folder).accepted == nil)
        try Data("not json".utf8).write(to: record)
        #expect(BinderInstructions.record(folder).accepted == nil)
    }

    @Test func theBoundCountsBytesToo() {
        #expect(BinderInstructions.fits(String(repeating: "a", count: BinderInstructions.maxCharacters)))
        #expect(!BinderInstructions.fits(String(repeating: "a", count: BinderInstructions.maxCharacters + 1)))
        // 5,000 characters of 18 bytes each (a family emoji joined from three) are over 64 KiB.
        let wide = String(repeating: "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 5_000)
        #expect(wide.count == 5_000)
        #expect(!BinderInstructions.fits(wide))
        let cut = BinderInstructions(exists: true, section: "", text: wide).guidance
        #expect(cut?.cut == true && (cut?.text.utf8.count ?? .max) <= BinderInstructions.maxBytes)
    }

    @Test func oldManualsAreOfferedWhenSetAside() throws {
        let folder = try binder()
        #expect(BinderInstructions.oldManuals(folder).isEmpty)
        let manuals = folder.appendingPathComponent(".sprava/adopted/manuals")
        try FileManager.default.createDirectory(at: manuals, withIntermediateDirectories: true)
        try Data("File receipts in receipts.\n".utf8).write(to: manuals.appendingPathComponent("CLAUDE.md.saved"))
        try Data("  \n".utf8).write(to: manuals.appendingPathComponent("AGENTS.md.saved"))
        let found = BinderInstructions.oldManuals(folder)
        #expect(found.map(\.name) == ["CLAUDE.md"])
        #expect(found.first?.text == "File receipts in receipts.\n")
    }
}
