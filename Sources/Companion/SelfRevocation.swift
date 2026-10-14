import CryptoKit
import Foundation

extension CompanionProfile {
    /// companion-v0 §§8.8, 9.2: relay status alone cannot revoke a local device.
    /// Caller holds the device decision lock and checks owner admission before acting on a valid proof.
    /// This only authenticates bytes; it never changes access, rotates keys or deletes anything.
    /// Invalid relay input returns false; unavailable/corrupt local state or credentials throw.
    public func verifySelfRevocation(deviceID: String, bytes: Data) throws -> Bool {
        guard CompanionWire.isID(deviceID), bytes.count <= 1024 else { return false }
        return try store.read { t in
            guard try record(deviceID, t)?.state == .active else { return false }
            guard let key = try secrets.read(account: deviceAccount(deviceID)) else { throw CompanionCredentialError.unavailable }
            guard key.count == 32 else { throw CompanionCredentialError.invalid }
            do {
                let plaintext = try CompanionSealedObject.openPlaintext(name: "devices/\(deviceID)/revocation",
                    epoch: 0, key: SymmetricKey(data: key), bytes: bytes)
                let payload = try CompanionWire.parse(plaintext, limit: 1024)
                // Generation and phone time are informative, never revocation authorities (§8.8).
                return payload["type"] == .string("revoke-self") && payload["device_id"] == .string(deviceID)
                    && payload["instance"] == .string(relay.instance)
            } catch { return false }
        }
    }
}
