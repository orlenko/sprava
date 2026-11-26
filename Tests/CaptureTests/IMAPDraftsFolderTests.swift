import BinderFormat
@testable import Capture
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// The Drafts folder the person chose, kept with the binder's email connection for a server that marks none or several
/// (issue #623). Temporary folders and invented names only.
@Suite(.serialized) struct IMAPDraftsFolderTests {
    typealias Fixture = BinderIMAPTests.Fixture

    @Test func threadArrivalsCountDistinctMessagesOnlyInTheDraftsConnectionAfterItWasWritten() throws {
        let f = try Fixture()
        let conn = f.configuration.id, start = Date(timeIntervalSince1970: 1000)
        func arrived(_ uid: UInt32, _ id: String, _ seconds: TimeInterval) throws {
            try f.store.recordImport(conn, validity: 1, uid: uid, path: "intake/mail/invented-\(uid).md",
                                     messageID: id, threadIDs: ["<root@example.invalid>", "<parent@example.invalid>"],
                                     now: start.addingTimeInterval(seconds))
        }
        try arrived(1, "<first@example.invalid>", -60)
        try arrived(2, "<second@example.invalid>", 60)
        try arrived(3, "<second@example.invalid>", 80)
        let refs = ["<root@example.invalid>", "<parent@example.invalid>"]
        #expect(try f.store.arrivals(in: conn, matching: refs, since: start) == 1)
        #expect(try f.store.arrivals(in: UUID(), matching: refs, since: start) == 0)
        #expect(try f.store.arrivals(in: conn, matching: ["<other@example.invalid>"], since: start) == 0)
    }

    @Test func theChosenFolderIsKeptAndKeepsTheCursor() throws {
        let f = try Fixture()
        #expect(f.configuration.draftsFolder == nil)
        let chosen = try f.store.configure(folder: f.folder, account: Fixture.account, mailbox: "INBOX/Workshop", draftsFolder: "Brouillons")
        #expect(chosen.draftsFolder == "Brouillons")
        // Where drafts go changes nothing about what is fetched: the same connection keeps its cursor and receipts.
        #expect(chosen.id == f.configuration.id)
        #expect(try f.store.configuration(for: f.folder)?.draftsFolder == "Brouillons")
        // Saving again with none, or an empty name, goes back to the folder the server marks.
        #expect(try f.store.configure(folder: f.folder, account: Fixture.account, mailbox: "INBOX/Workshop", draftsFolder: "").draftsFolder == nil)
        #expect(try f.store.configuration(for: f.folder)?.draftsFolder == nil)
    }

    @Test func aNameTheWorkerWouldRefuseIsNeverKept() throws {
        let f = try Fixture()
        for bad in ["Drafts\r\nDELETE INBOX", "Drafts\u{7F}", String(repeating: "d", count: 1_025)] {
            #expect(throws: BinderIMAPConnections.Refused.invalidConfiguration) {
                try f.store.configure(folder: f.folder, account: Fixture.account, mailbox: "INBOX/Workshop", draftsFolder: bad)
            }
        }
        #expect(try f.store.configuration(for: f.folder)?.draftsFolder == nil)
    }

    @Test func aRowWrittenBeforeTheChoiceStillReadsAndNoneIsWrittenAsBefore() throws {
        let f = try Fixture()
        let with = try f.store.configure(folder: f.folder, account: Fixture.account, mailbox: "INBOX/Workshop", draftsFolder: "Brouillons")
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(with)) as? [String: Any])
        #expect(object["draftsFolder"] as? String == "Brouillons")
        object.removeValue(forKey: "draftsFolder")
        let old = try JSONDecoder().decode(BinderIMAPConnections.Configuration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.draftsFolder == nil && old.mailbox == with.mailbox)
        let without = try f.store.configure(folder: f.folder, account: Fixture.account, mailbox: "INBOX/Workshop")
        let written = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(without)) as? [String: Any])
        #expect(written["draftsFolder"] == nil)
    }
}
