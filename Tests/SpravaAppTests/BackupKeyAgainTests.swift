import Foundation
@testable import SpravaApp
import SpravaKit
import Testing

/// The Backup page when the runtime cannot read the key of a configured backup, and when iCloud Keychain went
/// unchecked. A stand-in runtime and invented keys only.
@MainActor
@Suite struct BackupKeyAgainTests {
    @MainActor
    final class StandIn {
        var keyUnavailable = true
        var unchecked = true
        var setups: [JSONValue] = []
        var refusal: String?

        lazy var client = RuntimeClient(answer: { [self] text in
            let r = try JSONParser.parse(text).value
            if r["command"] == .str("backup_setup") {
                setups.append(r)
                if let refusal { return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .string(refusal))])) }
                keyUnavailable = false
                return #"{"ok":true,"icloud_keychain_unchecked":true}"#
            }
            // Set up, but with no readable key: not configured, as the runtime reports it.
            return JSONWriter.compact(.obj([("ok", .bool(true)), ("configured", .bool(!keyUnavailable)), ("primary", .str("/Invented/Mirror")),
                                            ("key_unavailable", .bool(keyUnavailable)), ("icloud_keychain", .bool(true)),
                                            ("icloud_keychain_unchecked", .bool(unchecked)), ("binders", .array([])), ("requests", .array([]))]))
        })
    }

    @Test func aKeyTypedAgainGoesToTheSameMirrorWithTheSameICloudChoice() async throws {
        let runtime = StandIn()
        let model = BackupModel(client: runtime.client)
        await model.load()
        #expect(model.keyUnavailable && model.iCloudKeychain)
        model.typedKey = "INVNT-KEYAA-KEYBB"
        await model.reenterKey()
        let sent = try #require(runtime.setups.first)
        #expect(sent == .obj([("command", .str("backup_setup")), ("key", .str("INVNT-KEYAA-KEYBB")), ("primary", .str("/Invented/Mirror")),
                              ("icloud_keychain", .bool(true))]))
        #expect(model.typedKey.isEmpty && model.message == "The backup key is in use again.")
        #expect(!model.keyUnavailable)
    }

    /// A key the runtime refuses (it does not open the mirror) keeps what was typed, so it can be corrected.
    @Test func aRefusedKeyIsKeptForCorrection() async {
        let runtime = StandIn()
        runtime.refusal = "backup key does not open the repository"
        let model = BackupModel(client: runtime.client)
        await model.load()
        model.typedKey = "INVNT-WRONG"
        await model.reenterKey()
        #expect(model.typedKey == "INVNT-WRONG")
        #expect(model.message == "The backup key was not used: backup key does not open the repository")
        #expect(model.keyUnavailable)
    }

    @Test func nothingIsSentUnlessTheKeyIsUnavailableAndOneIsTyped() async {
        let runtime = StandIn()
        let model = BackupModel(client: runtime.client)
        model.typedKey = "INVNT-KEYAA"
        await model.reenterKey()   // the runtime has not answered yet
        await model.load()
        #expect(model.configured == false && model.keyUnavailable)
        model.typedKey = ""
        await model.reenterKey()
        runtime.keyUnavailable = false
        await model.load()
        model.typedKey = "INVNT-KEYAA"
        await model.reenterKey()   // a readable key needs no re-entry
        #expect(runtime.setups.isEmpty)
    }

    /// The unchecked iCloud Keychain warning comes from the backup's own settings, so a reopened page shows it again.
    @Test func theUncheckedICloudKeychainWarningIsShownAgainAfterReopening() async {
        let runtime = StandIn()
        await BackupModel(client: runtime.client).load()
        let reopened = BackupModel(client: runtime.client)
        await reopened.load()
        #expect(reopened.iCloudKeychainUnchecked)
        runtime.unchecked = false
        await reopened.load()
        #expect(!reopened.iCloudKeychainUnchecked)
    }
}
