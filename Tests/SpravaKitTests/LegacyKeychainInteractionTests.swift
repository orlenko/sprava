import Foundation
import LocalAuthentication
import Security
import SpravaKit
import Testing

/// The login Keychain's dialogs follow one process-wide switch, never the query's context: each login call runs with
/// the switch set from that context and put back after. A stand-in switch only; no Keychain call is made.
@Suite struct LegacyKeychainInteractionTests {
    final class Recorded: @unchecked Sendable {
        let lock = NSLock()
        var value = true
        var sets: [Bool] = []
        var interaction: LegacyKeychainInteraction.Switch {
            LegacyKeychainInteraction.Switch(get: { [self] in lock.withLock { value } },
                                             set: { [self] v in lock.withLock { value = v; sets.append(v) } })
        }
    }

    func query(login: Bool, interactive: Bool?) -> [String: Any] {
        var q: [String: Any] = [kSecUseDataProtectionKeychain as String: !login]
        if let interactive {
            let context = LAContext()
            context.interactionNotAllowed = !interactive
            q[kSecUseAuthenticationContext as String] = context
        }
        return q
    }

    @Test func anUnattendedLoginCallRunsWithDialogsOffAndPutsTheSwitchBack() {
        let recorded = Recorded()
        let seen = LegacyKeychainInteraction.run(query(login: true, interactive: false), switch: recorded.interaction) { recorded.value }
        #expect(seen == false)
        #expect(recorded.value == true && recorded.sets == [false, true])
    }

    @Test func theLoginCallOfAnExplicitSaveMayAsk() {
        let recorded = Recorded()
        recorded.value = false
        let seen = LegacyKeychainInteraction.run(query(login: true, interactive: true), switch: recorded.interaction) { recorded.value }
        #expect(seen == true && recorded.value == false)
    }

    /// No context counts as unattended; data-protection calls leave the switch alone.
    @Test func noContextNeverAsksAndDataProtectionCallsPassThrough() {
        let recorded = Recorded()
        #expect(LegacyKeychainInteraction.run(query(login: true, interactive: nil), switch: recorded.interaction) { recorded.value } == false)
        recorded.sets = []
        _ = LegacyKeychainInteraction.run(query(login: false, interactive: false), switch: recorded.interaction) { 0 }
        #expect(recorded.sets.isEmpty)
    }
}
