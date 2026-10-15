import BinderFormat
import Foundation
import Testing
@testable import Retrieval

@Suite struct HelperDocumentReaderTests {
    @Test func aPlainTextDocumentIsIndexedAsItsOnePage() throws {
        let f = try IndexFixture(extraDocuments: #", {"id": "condo-example-doc-2026-006", "title": "Notes", "path": "notes/meeting.txt"}"#)
        let folder = f.binder.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data("The elevator inspection is booked for the spring.".utf8)
        try bytes.write(to: folder.appendingPathComponent("meeting.txt"))
        let reader = HelperDocumentReader(binder: f.binder, reader: .inProcess)
        let record = DocumentRecord(id: .string("condo-example-doc-2026-006"), path: "notes/meeting.txt")
        #expect(reader.revision(of: record) == bytes.sha256Hex)
        let text = reader.read(record)
        #expect(text.problem == nil && text.language == "en")
        #expect(text.pages.count == 1 && text.pages[0].number == 1)
        let index = try BinderIndex.rebuild(binder: f.binder, teka: f.teka, reader: reader, trust: f.trust)
        let hit = try #require(try index.search("elevator inspection").hits.first)
        #expect(hit.passage.page == 1 && hit.passage.revision == bytes.sha256Hex)
        // The fixture's other documents are not on disk: each is named as not indexed, never left out silently.
        #expect(try index.coverage().documents.filter { $0.notIndexed == "the file cannot be read now" }.count == 3)
    }

    @Test func aMissingHelperIsTriedAgainOnceItIsThere() throws {
        let f = try IndexFixture()
        let folder = f.binder.appendingPathComponent("bills")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Water service invoice for unit 4B.".utf8).write(to: folder.appendingPathComponent("water-bill.pdf"))
        let index = try BinderIndex.rebuild(binder: f.binder, teka: f.teka, reader: HelperDocumentReader(binder: f.binder, reader: .missing), trust: f.trust)
        #expect(try index.coverage().documents.first { $0.document == billID.description }?.notIndexed?.contains("sprava-extract") == true)
        try index.refresh(teka: f.teka, reader: HelperDocumentReader(binder: f.binder, reader: .inProcess))
        #expect(try index.search("invoice").hits.first?.passage.source == .document(billID))
    }

    @Test func aMessagesAttachmentsAreNamedAsLeftOut() throws {
        let f = try IndexFixture(extraDocuments: #", {"id": "condo-example-doc-2026-007", "title": "Mail", "path": "mail/notice.eml"}"#)
        let folder = f.binder.appendingPathComponent("mail")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        From: manager@example.com\r\nSubject: Notice\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="b"\r\n\r\n\
        --b\r\nContent-Type: text/plain\r\n\r\nThe roof repair starts Monday.\r\n--b\r\nContent-Type: text/plain\r\n\
        Content-Disposition: attachment; filename="plan.txt"\r\n\r\nPlan\r\n--b--\r\n
        """.utf8).write(to: folder.appendingPathComponent("notice.eml"))
        let text = HelperDocumentReader(binder: f.binder, reader: .inProcess).read(DocumentRecord(id: .string("condo-example-doc-2026-007"), path: "mail/notice.eml"))
        #expect(text.notes == ["1 attachment(s) are not indexed with the message"])
    }

    @Test func aLinkOnTheWayIsNeverFollowed() throws {
        let f = try IndexFixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("private text outside the binder".utf8).write(to: outside.appendingPathComponent("bylaws.pdf"))
        try FileManager.default.createSymbolicLink(at: f.binder.appendingPathComponent("governance"), withDestinationURL: outside)
        let reader = HelperDocumentReader(binder: f.binder, reader: .inProcess)
        let record = DocumentRecord(id: bylawsID, path: "governance/bylaws.pdf")
        #expect(reader.revision(of: record) == nil)
        #expect(reader.read(record).problem?.hasPrefix("the file was not opened") == true)
    }

    @Test func aNULInAPathNeverOpensTheFileBeforeIt() throws {
        let f = try IndexFixture(extraDocuments: #", {"id": "x-key", "title": "x", "path": "keys/private.pem\u0000/notes.txt"}"#)
        try FileManager.default.createDirectory(at: f.binder.appendingPathComponent("keys"), withIntermediateDirectories: true)
        try Data("invented private key material".utf8).write(to: f.binder.appendingPathComponent("keys/private.pem"))
        let reader = HelperDocumentReader(binder: f.binder, reader: .inProcess)
        #expect(reader.revision(of: DocumentRecord(id: .string("x-key"), path: "keys/private.pem\u{0}/notes.txt")) == nil)
        let index = try BinderIndex.rebuild(binder: f.binder, teka: f.teka, reader: reader, trust: f.trust)
        #expect(try index.search("invented private key material").hits.isEmpty)
        #expect(try index.coverage().documents.first { $0.document == "x-key" }?.notIndexed == "its path holds a control character")
    }
}
