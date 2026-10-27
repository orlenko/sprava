import Foundation
import Security
import SpravaKit

/// IMAP account passwords: one item per account in the non-synchronized Keychain service
/// `org.sprava.imap` (integrations.md 2.1, decisions.md A20). LocalKeychainSecret supports both provisioned
/// and ad-hoc builds. A password enters the cache only after a successful persistent save.
public final class IMAPPasswords: @unchecked Sendable {
    public enum Refused: Error { case unavailable }
    public struct Backend: Sendable {
        let load: @Sendable (String) -> (OSStatus, Data?)
        let save: @Sendable (String, Data?) -> OSStatus
        public init(load: @escaping @Sendable (String) -> (OSStatus, Data?), save: @escaping @Sendable (String, Data?) -> OSStatus) {
            self.load = load; self.save = save
        }
    }
    private let lock = NSLock()
    private let backend: Backend
    private var memory: [String: String] = [:]

    public init(backend: Backend = .keychain) { self.backend = backend }

    public func read(_ account: IMAPAccount) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if let value = memory[account.key] { return value }
        let (status, data) = backend.load(account.key)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= 1_024, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw Refused.unavailable
        }
        memory[account.key] = value
        return value
    }

    public func store(_ password: String, for account: IMAPAccount) throws {
        guard !password.isEmpty, password.utf8.count <= 1_024 else { throw Refused.unavailable }
        lock.lock(); defer { lock.unlock() }
        let status = backend.save(account.key, Data(password.utf8))
        guard status == errSecSuccess else { throw Refused.unavailable }
        memory[account.key] = password
    }

    public func remove(_ account: IMAPAccount) {
        lock.lock(); defer { lock.unlock() }
        memory[account.key] = nil
        _ = backend.save(account.key, nil)
    }
}

extension IMAPPasswords.Backend {
    private static let item = LocalKeychainSecret(service: "org.sprava.imap", label: "Sprava email intake")
    public static let keychain = IMAPPasswords.Backend(load: { key in
        item.read(account: key)
    }, save: { key, data in
        item.write(data, account: key, allowInteraction: data != nil)
    })
}
