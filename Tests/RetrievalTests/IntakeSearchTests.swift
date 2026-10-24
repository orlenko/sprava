import BinderFormat
import Foundation
import Testing
@testable import Retrieval

@Suite struct IntakeSearchTests {
    let mail = "intake/mail/notice.md"
    let attachment = "intake/mail/notice/board-letter.txt"

    func reading(_ text: String, revision: String = "mail-1") -> DocumentText {
        DocumentText(revision: revision, language: "en", pages: [(1, .read(text, from: "parsed"))])
    }

    @Test func intakeMailIsSearchableOnlyWhenExplicitlyIncludedWithItsSource() throws {
        var f = try IndexFixture()
        f.reader.texts[mail] = reading("From: manager@example.com\nSubject: Inspection reply\nPlease confirm the workshop inspection.")
        f.reader.texts[attachment] = reading("The board letter permits a small dog with written permission.")
        let index = try f.rebuild()
        #expect(try !index.coverage(teka: f.teka, intake: true).intakeManifestIndexed)
        try index.refreshIntake(paths: [mail, attachment], reader: f.reader)
        #expect(try index.search("workshop inspection").hits.isEmpty)
        #expect(try !index.coverage().documents.contains { $0.document.hasPrefix("intake:") })
        let hit = try #require(try index.search("workshop inspection", intake: true).hits.first)
        #expect(hit.passage.source == .intake(mail) && hit.passage.revision == "mail-1")
        #expect(hit.passage.page == 1 && hit.passage.text.contains("manager@example.com"))
        #expect(try index.search("board letter", intake: true).hits.contains { $0.passage.source == .intake(attachment) })
        // Filed bylaws remain searchable with their own page citation alongside intake results.
        #expect(try index.search("pets consent", intake: true).hits.contains { $0.passage.source == .document(bylawsID) && $0.passage.page == 2 })
        #expect(try index.coverage(intake: true).intakeManifestIndexed)
    }

    @Test func intakeChangesAndRemovalCannotLeaveOldMailAsCurrent() throws {
        var f = try IndexFixture()
        f.reader.texts[mail] = reading("The inspection is on Tuesday.")
        let index = try f.rebuild()
        try index.refreshIntake(paths: [mail], reader: f.reader)
        try index.refresh(teka: f.teka, reader: f.reader)
        #expect(try !index.search("Tuesday", intake: true).hits.isEmpty)
        f.reader.texts[mail] = reading("The inspection is on Thursday.", revision: "mail-2")
        try index.refreshIntake(paths: [mail], reader: f.reader)
        #expect(try index.search("Tuesday", intake: true).hits.isEmpty)
        #expect(try index.search("Thursday", intake: true).hits.first?.passage.revision == "mail-2")
        f.reader.texts[mail] = nil
        try index.refreshIntake(paths: [mail], reader: f.reader)
        #expect(try index.search("Thursday", intake: true).hits.isEmpty)
        #expect(try index.coverage(intake: true).gaps.contains { $0.document == "intake:\(mail)" })
        try index.refreshIntake(paths: [], reader: f.reader)
        #expect(try !index.coverage(intake: true).documents.contains { $0.document.hasPrefix("intake:") })
    }

    @Test(arguments: ["intake/.env", "scripts/mail/.env", "intake/mail/state.json", "intake/../outside.txt",
                      "intake/notes\u{0}.txt", "/intake/mail.md", "intake/mail/id_rsa", "intake/./mail.md"])
    func credentialAndEscapingPathsNeverReachTheReader(path: String) throws {
        let f = try IndexFixture()
        let index = try f.rebuild()
        let reader = FakeReader(texts: [path: reading("Invented credential canary")])
        #expect(throws: BinderIndex.Failure.self) { try index.refreshIntake(paths: [path], reader: reader) }
        #expect(reader.reads.all.isEmpty)
        #expect(try index.search("canary", intake: true).hits.isEmpty)
    }

    @Test func aManifestCannotExhaustMemoryWithUnlimitedSources() throws {
        let f = try IndexFixture()
        let index = try f.rebuild()
        let reader = FakeReader()
        #expect(throws: BinderIndex.Failure.self) {
            try index.refreshIntake(paths: Array(repeating: mail, count: BinderIndex.maximumIntakeSources + 1), reader: reader)
        }
        #expect(reader.reads.all.isEmpty)
    }

    @Test func aProductionReaderDoesNotFollowAnIntakeSymlink() throws {
        let f = try IndexFixture()
        let outside = f.binder.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("Never disclose this invented outside canary".utf8).write(to: outside.appendingPathComponent("notice.md"))
        try FileManager.default.createSymbolicLink(at: f.binder.appendingPathComponent("intake"), withDestinationURL: outside)
        let index = try f.rebuild()
        try index.refreshIntake(paths: ["intake/notice.md"], reader: HelperDocumentReader(binder: f.binder, reader: .inProcess))
        #expect(try index.search("outside canary", intake: true).hits.isEmpty)
        #expect(try index.coverage(intake: true).gaps.contains { $0.document == "intake:intake/notice.md" })
    }

    @Test func markdownMailKeepsItsReplyIdentityInTheIndexedText() throws {
        let f = try IndexFixture()
        let folder = f.binder.appendingPathComponent("intake/mail")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        ---
        Subject: Workshop inspection
        From: workshopdesk@example.com
        To: resident@example.com
        Date: 2026-10-24
        ---
        Please confirm the inspection on Thursday.
        """.utf8).write(to: f.binder.appendingPathComponent(mail))
        let attachments = f.binder.appendingPathComponent("intake/mail/notice")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("Animalpolicy attachment: written board permission is required.".utf8)
            .write(to: f.binder.appendingPathComponent(attachment))
        let index = try f.rebuild()
        try index.refreshIntake(paths: [mail, attachment], reader: HelperDocumentReader(binder: f.binder, reader: .inProcess))
        let hits = try index.search("workshopdesk", intake: true).hits
        #expect(hits.count == 1)
        #expect(hits.first?.passage.text.contains("Subject: Workshop inspection") == true)
        #expect(hits.first?.passage.text.contains("Please confirm the inspection") == true)
        #expect(try index.search("Animalpolicy", intake: true).hits.first?.passage.source == .intake(attachment))
    }

    @Test func emlKeepsTheMessageIDForALaterReplyDraft() throws {
        let f = try IndexFixture()
        try FileManager.default.createDirectory(at: f.binder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        let path = "intake/inspection.eml"
        try Data("From: workshopdesk@example.com\r\nTo: resident@example.com\r\nSubject: Inspection\r\nMessage-ID: <invented-inspection@example.com>\r\n\r\nThursday works.".utf8)
            .write(to: f.binder.appendingPathComponent(path))
        let index = try f.rebuild()
        try index.refreshIntake(paths: [path], reader: HelperDocumentReader(binder: f.binder, reader: .inProcess))
        let hit = try #require(try index.search("workshopdesk", intake: true).hits.first)
        #expect(hit.passage.text.contains("Message-ID: <invented-inspection@example.com>"))
    }
}
