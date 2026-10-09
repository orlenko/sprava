@testable import BinderFormat
import CryptoKit
import Darwin
import Foundation
import Testing

/// Regressions from the fourth adversarial review of increment 1 (key and credential files in intake, hub
/// withdrawal while the outbox fails, private corrections that close items, correction cards that could not be
/// kept, unreadable op logs, exhausted id sequences) and the MCP socket's modes. Invented data only.
@Suite(.serialized) struct AstraReview4Tests {
    // MARK: - 1. Key and credential files are never read

    @Test func keyFileNamesFollowTheBinderRule() {
        for name in ["secret.pem", "Server.KEY", "cert.p12", "cert.pfx", "id_rsa", "id_ed25519.pub", "id_ecdsa", "backup.age",
                     "age-identity.txt", ".netrc", "credentials.json", "Credentials-2026.txt", "token-api.json", "login.keychain-db",
                     ".env", ".env.local", "intake/mail/sub/id_rsa"] {
            #expect(DocumentPaths.isKeyFile(name), "\(name)")
        }
        for name in ["notice.txt", "keynote.pdf", "monkey.pdf", "tokens.txt", "environment.md", "levy.pdf", "pemberton.pdf"] {
            #expect(!DocumentPaths.isKeyFile(name), "\(name)")
        }
    }
}
