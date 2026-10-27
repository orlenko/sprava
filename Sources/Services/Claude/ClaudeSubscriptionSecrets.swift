import Foundation
import Security
import SpravaKit

/// The application's own subscription item only. Constructing the backend performs no credential read;
/// only an authenticated app action can enable the account. Tests inject an invented memory store.
enum ClaudeSubscriptionSecrets {
    enum Refused: Error { case unavailable }
    private static let item = LocalKeychainSecret(service: "org.sprava.claude.subscription", label: "Sprava Claude subscription")
    private static let storage = ClaudeCredentialStorage(load: {
        item.read(account: "app-account")
    }, save: { value in
        if let value {
            let data = Data(value.utf8)
            guard !data.isEmpty, data.count <= 16_384 else { throw Refused.unavailable }
            return item.write(data, account: "app-account", allowInteraction: true)
        } else {
            return item.write(nil, account: "app-account")
        }
    })
    static let keychain = ClaudeConversationRuntime.Secrets(read: { try storage.read() }, replace: { try storage.replace($0) }, persistent: { storage.persistent })
}

/// Cache only credentials that the Keychain accepted. A storage failure is visible and never
/// presents a memory-only sign-in as one that will survive a runtime restart (decisions.md A20).
final class ClaudeCredentialStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let load: @Sendable () -> (OSStatus, Data?)
    private let save: @Sendable (String?) throws -> OSStatus
    private var credential: String?
    private var remembered = false
    init(load: @escaping @Sendable () -> (OSStatus, Data?), save: @escaping @Sendable (String?) throws -> OSStatus) {
        self.load = load; self.save = save
    }
    var persistent: Bool { lock.lock(); defer { lock.unlock() }; return remembered }
    func read() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if let credential { return credential }
        let (status, data) = load()
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= 16_384,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw ClaudeSubscriptionSecrets.Refused.unavailable }
        credential = value; remembered = true; return value
    }
    func replace(_ value: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let status = try save(value)
        guard status == errSecSuccess else { throw ClaudeSubscriptionSecrets.Refused.unavailable }
        credential = value; remembered = status == errSecSuccess
    }
}
