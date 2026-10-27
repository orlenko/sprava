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

    @Test(arguments: [errSecMissingEntitlement, errSecInteractionNotAllowed, errSecDecode])
    func anUnavailableKeychainNeverPretendsToSaveAPassword(_ refusal: OSStatus) throws {
        let items = Items(); items.status = refusal
        let passwords = IMAPPasswords(backend: items.backend)
        #expect(throws: IMAPPasswords.Refused.self) { try passwords.store("invented-password", for: Self.account) }
        #expect(throws: IMAPPasswords.Refused.self) { try passwords.read(Self.account) }
        #expect(items.values.isEmpty)
    }
}
