import BinderFormat
@testable import Capture
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// The person's own addresses, kept with their email connections, so mail they wrote proposes no to-dos (issue #594).
/// Temporary folders and invented addresses only.
@Suite(.serialized) struct IMAPOwnAddressesTests {
    typealias Fixture = BinderIMAPTests.Fixture

    @Test func otherAddressesAreKeptLowerCaseOnceAndKeepTheCursor() throws {
        let f = try Fixture()
        let changed = try f.store.configure(folder: f.folder, account: Fixture.account, mailbox: "INBOX/Workshop",
                                            ownAddresses: ["Me@Example.Invalid", "me@example.invalid", " Other@example.com "])
        #expect(changed.ownAddresses == ["me@example.invalid", "other@example.com"])
        // Giving addresses changes nothing about what is fetched, so the same connection keeps its cursor and receipts.
        #expect(changed.id == f.configuration.id)
        #expect(try f.store.configuration(for: f.folder)?.ownAddresses == ["me@example.invalid", "other@example.com"])
        // Saving again without them clears them.
        #expect(try f.store.configure(folder: f.folder, account: Fixture.account, mailbox: "INBOX/Workshop").ownAddresses.isEmpty)
    }

    @Test func junkOrTooManyAddressesAreRefused() throws {
        let f = try Fixture()
        // Two addresses in one entry, or a display name, are refused whole, never cut down to the first address.
        for bad in [["not an address"], ["a@example.com, b@example.com"], ["first@example.com second@example.com"],
                    ["Invented Person <other@example.com>"], [""],
                    (0...BinderIMAPConnections.maxOwnAddresses).map { "person\($0)@example.com" }] {
            #expect(throws: BinderIMAPConnections.Refused.self) {
                try f.store.configure(folder: f.folder, account: Fixture.account, mailbox: "INBOX/Workshop", ownAddresses: bad)
            }
        }
        #expect(try f.store.configuration(for: f.folder)?.ownAddresses.isEmpty == true)
    }

    @Test func aRowWrittenBeforeOtherAddressesStillReads() throws {
        let f = try Fixture()
        let with = try f.store.configure(folder: f.folder, account: Fixture.account, mailbox: "INBOX/Workshop", ownAddresses: ["me@example.invalid"])
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(with)) as? [String: Any])
        #expect(object["otherAddresses"] != nil)
        object.removeValue(forKey: "otherAddresses")
        let old = try JSONDecoder().decode(BinderIMAPConnections.Configuration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.ownAddresses.isEmpty)
        #expect(old.account == with.account && old.mailbox == with.mailbox)
        // A connection without other addresses is written exactly as before they existed.
        let without = try f.store.configure(folder: f.folder, account: Fixture.account, mailbox: "INBOX/Workshop")
        let written = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(without)) as? [String: Any])
        #expect(written["otherAddresses"] == nil)
    }

    @Test func theOwnAddressesAreEveryConnectionsAccountAndOtherAddresses() throws {
        let f = try Fixture()
        let second = try makeTeka(fixture: "sprava-v0")
        let work = try #require(IMAPAccount(host: "mail.example.invalid", port: 993, security: .tls, user: "Work@Example.com"))
        _ = try f.store.configure(folder: second, account: work, mailbox: "Sent", ownAddresses: ["alias@example.org"])
        let bridge = try #require(IMAPAccount(host: "127.0.0.1", port: 1143, security: .startTLS, user: "bridge-login"))
        let third = try makeTeka(fixture: "sprava-v0")
        _ = try f.store.configure(folder: third, account: bridge, mailbox: "INBOX", ownAddresses: ["old@example.net"])
        try f.store.disable(folder: third)
        // An account name that is no address adds nothing; a disabled connection's addresses are still the person's.
        #expect(BinderIMAPConnections.ownAddresses(support: f.support) == ["member@example.invalid", "work@example.com", "alias@example.org", "old@example.net"])
    }

    @Test func noConnectionMeansNoAddressesAndNoStore() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-imap-none-" + UUID().uuidString)
        try AtomicFile.makePrivateFolder(support)
        #expect(BinderIMAPConnections.ownAddresses(support: support).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("capture/imap.sqlite").path))
    }
}
