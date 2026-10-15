import BinderFormat
import Foundation
import Testing
@testable import Retrieval

@Suite struct IndexFreshnessTests {
    @Test func aChangedDocumentLosesItsOldPassagesAndTranslations() throws {
        var f = try IndexFixture()
        let index = try f.rebuild()
        let original = try #require(try index.passages(of: letterID).first)
        try index.addTranslation(of: original.id, text: "Pets are allowed with the written consent of the board.", language: "en", translator: "t")
        f.reader.texts["correspondence/lettre-syndic.pdf"] = DocumentText(revision: "letter-2", language: "fr", pages: [
            (1, .read("Les animaux sont interdits dans la piscine.", from: "text-layer"))])
        // A file that cannot be read now loses its passages too: an old text is never kept as current.
        f.reader.texts["bills/water-bill.pdf"] = nil
        try index.refresh(teka: f.teka, reader: f.reader)
        #expect(try index.search("invoice").hits.isEmpty)
        #expect(try !index.search("consent pets allowed").hits.contains { $0.passage.source == .document(letterID) })
        #expect(try index.search("piscine").hits.first?.passage.revision == "letter-2")
        #expect(try index.coverage().translationLanguages.isEmpty)
        #expect(try index.coverage().documents.first { $0.document == billID.description }?.notIndexed == "the file cannot be read now")
        // An unchanged document is not read again.
        #expect(f.reader.reads.all.filter { $0 == "governance/bylaws.pdf" }.count == 1)
    }

    @Test func oneDocumentIsUpdatedAndARemovedOneLeaves() throws {
        var f = try IndexFixture()
        let index = try f.rebuild()
        f.reader.texts["bills/water-bill.pdf"] = DocumentText(revision: "bill-2", language: "en", pages: [(1, .read("Final notice for unit 4B.", from: "text-layer"))])
        try index.update(document: billID, teka: f.teka, reader: f.reader)
        #expect(try index.search("final notice").hits.first?.passage.revision == "bill-2")
        try f.edit(billID.description, "condo-example-doc-2026-099")
        try index.update(document: billID, teka: f.teka, reader: f.reader)
        #expect(try index.search("final notice").hits.isEmpty)
    }

    @Test func aChangedItemIsCutAgain() throws {
        let f = try IndexFixture()
        let index = try f.rebuild()
        try f.edit("about a parking permit", "about a bicycle rack")
        try index.refresh(teka: f.teka, reader: f.reader)
        #expect(try index.search("parking").hits.isEmpty)
        #expect(try index.search("bicycle").hits.count == 1)
    }

    @Test func placesSpravaNeverReadsAreNotIndexed() throws {
        let paths = [".claude/notes.md", "scripts/mail.pdf", "keys/id_rsa", "intake/mail/state.json", "../outside.pdf"]
        var f = try IndexFixture(extraDocuments: paths.enumerated().map { #", {"id": "x-\#($0.offset)", "title": "x", "path": "\#($0.element)"}"# }.joined())
        for path in paths { f.reader.texts[path] = DocumentText(revision: "r", language: "en", pages: [(1, .read("secret token", from: "parsed"))]) }
        let index = try f.rebuild()
        #expect(try index.search("secret token").hits.isEmpty)
        #expect(try index.coverage().documents.filter { $0.notIndexed != nil }.count == 5)
        #expect(Set(f.reader.reads.all) == Set(f.reader.texts.keys).subtracting(paths))
    }

    @Test func anIndexThisInstallationDidNotCreateIsRemovedNotOpened() throws {
        let f = try IndexFixture()
        let file = f.binder.appendingPathComponent(".sprava/index.sqlite")
        try Data("planted".utf8).write(to: file)
        #expect(try BinderIndex.open(binder: f.binder, trust: f.trust) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        _ = try f.rebuild()
        #expect(try BinderIndex.open(binder: f.binder, trust: f.trust) != nil)
        // A damaged index of its own is removed for a rebuild, never a failure that blocks search.
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(repeating: 0x41, count: 100))
        try handle.close()
        #expect(try BinderIndex.open(binder: f.binder, trust: f.trust) == nil)
        _ = try f.rebuild()
        // A copy of a real index put in its place is another file: rebuilt, never opened.
        let copy = f.binder.appendingPathComponent(".sprava/copy.sqlite")
        try FileManager.default.copyItem(at: file, to: copy)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: copy, to: file)
        #expect(try BinderIndex.open(binder: f.binder, trust: f.trust) == nil)
        // A binder without `.sprava` is not adopted: no index is made in it.
        try FileManager.default.removeItem(at: f.binder.appendingPathComponent(".sprava"))
        #expect(throws: BinderIndex.Failure.self) { try f.rebuild() }
    }
}
