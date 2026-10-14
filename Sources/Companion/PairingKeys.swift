import CryptoKit
import Foundation

/// Provisional material: the owner confirms the code and durably installs pairing state separately.
public struct CompanionPairingKeys {
    public let wrap: SymmetricKey
    public let device: SymmetricKey
    public let confirmation: String
    public let ownerPublicKey: Data
}
public enum CompanionPairing {
    public static func derive(pairingID: String, deviceID: String, devicePublicKey: Data,
                              owner: Curve25519.KeyAgreement.PrivateKey) throws -> CompanionPairingKeys {
        guard CompanionWire.isID(pairingID), CompanionWire.isID(deviceID), devicePublicKey.count == 32 else {
            throw CompanionWireError.invalid
        }
        do {
            let shared = try owner.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublicKey))
            guard shared.withUnsafeBytes({ $0.count == 32 && $0.contains(where: { $0 != 0 }) }) else { throw CompanionWireError.invalid }
            let a = owner.publicKey.rawRepresentation, d = try CompanionWire.decode(deviceID)
            func key(_ kind: String, _ count: Int) -> SymmetricKey {
                shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(pairingID.utf8),
                    sharedInfo: Data("sprava-companion/v0 \(kind)".utf8) + a + devicePublicKey + d, outputByteCount: count)
            }
            let code = try key("confirm", 4).withUnsafeBytes { try confirmation(Data($0)) }
            return CompanionPairingKeys(wrap: key("wrap", 32), device: key("device", 32), confirmation: code, ownerPublicKey: a)
        } catch { throw CompanionWireError.invalid }
    }
    public static func confirmation(_ bytes: Data) throws -> String {
        guard bytes.count == 4 else { throw CompanionWireError.invalid }
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let text = String(value); return String(repeating: "0", count: 6 - text.count) + text
    }
}
