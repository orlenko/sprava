import Foundation
import LocalAuthentication
import Security

/// The Mac login Keychain (the file-based one an ad-hoc build falls back to, decisions.md A20) ignores an `LAContext`:
/// whether a call may show an authorization dialog is one process-wide switch, `SecKeychainSetUserInteractionAllowed`.
/// Every login-Keychain call runs here, one at a time, with the switch set from its query's context (no context: no
/// dialog) and put back after, so an unattended read fails with `errSecInteractionNotAllowed` instead of waiting on a
/// dialog. Data-protection calls honour the context themselves and pass straight through.
package enum LegacyKeychainInteraction {
    /// The process-wide switch; tests pass their own.
    package struct Switch: Sendable {
        package var get: @Sendable () -> Bool
        package var set: @Sendable (Bool) -> Void

        package init(get: @escaping @Sendable () -> Bool, set: @escaping @Sendable (Bool) -> Void) {
            self.get = get; self.set = set
        }

        /// SecKeychain is deprecated, but this switch is the only control the login Keychain has over its dialogs.
        package static let system = Switch(get: {
            var allowed: DarwinBoolean = true
            return SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess ? allowed.boolValue : true
        }, set: { _ = SecKeychainSetUserInteractionAllowed($0) })
    }

    private static let lock = NSLock()

    /// Whether `query` goes to the login Keychain, and whether it may ask.
    package static func login(_ query: [String: Any]) -> (login: Bool, allowed: Bool) {
        let login = query[kSecUseDataProtectionKeychain as String] as? Bool != true
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        return (login, context.map { !$0.interactionNotAllowed } ?? false)
    }

    /// Runs `body` for `query`: a login-Keychain call under the lock with the switch set for it.
    package static func run<T>(_ query: [String: Any], switch interaction: Switch, _ body: () -> T) -> T {
        let (login, allowed) = login(query)
        guard login else { return body() }
        lock.lock()
        defer { lock.unlock() }
        let previous = interaction.get()
        interaction.set(allowed)
        defer { interaction.set(previous) }
        return body()
    }
}
