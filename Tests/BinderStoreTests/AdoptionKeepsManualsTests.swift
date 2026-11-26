import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// #692: adoption never copied the binder's old manuals aside, so the Instructions page had nothing to offer.
@Suite struct AdoptionKeepsManualsTests {
    private func adopt(_ folder: URL) throws {
        _ = try Adoption.adopt(folder, inRegistry: false, deviceID: "invented-device", today: today)
    }

    @Test func theManualsAtTheTopAreCopiedAsideAndLeftInPlace() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        let agents = "# Invented binder\n\nFile notices under the chapter they belong to.\n"
        let claude = "# Invented rules\n\nName files date first. Ünïcode stays as written.\n"
        try Data(agents.utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        try Data(claude.utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("chapters/invented"), withIntermediateDirectories: true)
        try Data("not at the top".utf8).write(to: folder.appendingPathComponent("chapters/invented/CLAUDE.md"))
        try adopt(folder)

        let offered = BinderInstructions.oldManuals(folder)
        #expect(offered.map(\.name) == ["AGENTS.md", "CLAUDE.md"])
        #expect(offered.map(\.text) == [agents, claude])
        // The originals stay where they were, byte for byte.
        #expect(try Data(contentsOf: folder.appendingPathComponent("AGENTS.md")) == Data(agents.utf8))
        #expect(try Data(contentsOf: folder.appendingPathComponent("CLAUDE.md")) == Data(claude.utf8))
        let saved = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".sprava/adopted/manuals").path).sorted()
        #expect(saved == ["AGENTS.md.saved", "CLAUDE.md.saved"])
        var info = stat()
        #expect(lstat(folder.appendingPathComponent(".sprava/adopted/manuals/CLAUDE.md.saved").path, &info) == 0 && info.st_mode & 0o077 == 0)
    }

    @Test func aBinderWithNoManualGetsNoFolderForThem() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("AGENTS.md"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("CLAUDE.md"))
        try adopt(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava/adopted/manuals").path))
        #expect(BinderInstructions.oldManuals(folder).isEmpty)
    }

    // A manual that is a link, a folder, or larger than the page reads is never copied: the adoption goes on without it.
    @Test func aLinkAFolderOrAnOversizedManualIsNotCopied() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("invented-outside-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("an invented file outside the binder".utf8).write(to: outside)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("AGENTS.md"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("CLAUDE.md"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("AGENTS.md"), withDestinationURL: outside)
        try Data(repeating: UInt8(ascii: "x"), count: BinderInstructions.fileLimit + 1).write(to: folder.appendingPathComponent("CLAUDE.md"))
        try adopt(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava/adopted/manuals").path))
        #expect(Teka.read(folder).isAdopted)

        let second = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: second) }
        try? FileManager.default.removeItem(at: second.appendingPathComponent("CLAUDE.md"))
        try FileManager.default.createDirectory(at: second.appendingPathComponent("CLAUDE.md"), withIntermediateDirectories: true)
        try adopt(second)
        #expect(!BinderInstructions.oldManuals(second).contains { $0.name == "CLAUDE.md" })
        #expect(Teka.read(second).isAdopted)
    }
}
