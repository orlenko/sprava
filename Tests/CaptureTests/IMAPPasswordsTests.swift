@testable import Capture
import Foundation
import Security
import Testing

@Suite struct IMAPPasswordsTests {
    final class Items: @unchecked Sendable {
        let lock = NSLock(); var values: [String: Data] = [:]; var status = errSecSuccess
        var backend: IMAPPasswords.Backend {
            IMAPPasswords.Backend(load: { key in
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.status == errSecSuccess else { return (self.status, nil) }
                return self.values[key].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
            }, save: { key, data in
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.status == errSecSuccess else { return self.status }
                self.values[key] = data; return errSecSuccess
            })
        }
    }
    static let account = IMAPAccount(host: "mail.example.invalid", port: 993, security: .tls, user: "member@example.invalid")!

    @Test func oneSignInServesEveryBinderOfTheAccountAndSurvivesARestart() throws {
        let items = Items()
        try IMAPPasswords(backend: items.backend).store("invented-password", for: Self.account)
        // A new runtime reads the same Keychain item.
        #expect(try IMAPPasswords(backend: items.backend).read(Self.account) == "invented-password")
        let other = try #require(Self.account.signing(in: "other@example.invalid"))
        #expect(try IMAPPasswords(backend: items.backend).read(other) == nil)
        IMAPPasswords(backend: items.backend).remove(Self.account)
        #expect(items.values.isEmpty)
    }

    @Test func aDevelopmentBuildKeepsThePasswordOnlyInMemoryAndADamagedKeychainFailsClosed() throws {
        let items = Items(); items.status = errSecMissingEntitlement
        let passwords = IMAPPasswords(backend: items.backend)
        try passwords.store("invented-password", for: Self.account)
        #expect(try passwords.read(Self.account) == "invented-password")
        // After a restart the binder asks again; nothing was written anywhere.
        #expect(try IMAPPasswords(backend: items.backend).read(Self.account) == nil)
        items.status = errSecInteractionNotAllowed
        #expect(throws: IMAPPasswords.Refused.self) { try IMAPPasswords(backend: items.backend).read(Self.account) }
        #expect(throws: IMAPPasswords.Refused.self) { try IMAPPasswords(backend: items.backend).store("invented", for: Self.account) }
    }
}
