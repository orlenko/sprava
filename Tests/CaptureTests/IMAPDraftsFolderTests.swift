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
