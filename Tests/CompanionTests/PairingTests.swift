import CryptoKit
import Foundation
import Testing
import Companion

@Test func ownerDerivationMatchesIndependentBrowserAndNodeVectors() throws {
    let v = try #require(WireFixtures.vectors()["pairing-derivation"])
    let owner = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: WireFixtures.hex(WireFixtures.text(v["owner_private_hex"])))
    let b = try CompanionWire.decode(WireFixtures.text(v["device_public_b64"]))
    for device in try #require(v["devices"]?.arrayValue) {
        let keys = try CompanionPairing.derive(pairingID: WireFixtures.text(v["pairing_id"]), deviceID: WireFixtures.text(device["device_id"]),
                                               devicePublicKey: b, owner: owner)
        let publicKey = try CompanionWire.decode(WireFixtures.text(v["owner_public_b64"]))
        let wrap = try WireFixtures.hex(WireFixtures.text(device["wrap_hex"])), deviceKey = try WireFixtures.hex(WireFixtures.text(device["device_hex"]))
        let confirmation = try WireFixtures.text(device["confirmation"])
        #expect(keys.ownerPublicKey == publicKey)
        #expect(keys.wrap.withUnsafeBytes { Data($0) } == wrap)
        #expect(keys.device.withUnsafeBytes { Data($0) } == deviceKey)
        #expect(keys.confirmation == confirmation)
    }
    #expect(throws: CompanionWireError.invalid) {
        try CompanionPairing.derive(pairingID: WireFixtures.text(v["pairing_id"]), deviceID: WireFixtures.id,
                                   devicePublicKey: Data(repeating: 0, count: 32), owner: owner)
    }
}
@Test func confirmationIsUnsignedBigEndianPaddedAndRejectsWrongLengths() throws {
    #expect(try CompanionPairing.confirmation(Data([0, 0, 0, 1])) == "000001")
    #expect(try CompanionPairing.confirmation(Data(repeating: 255, count: 4)) == "967295")
    for n in [0, 3, 5] { #expect(throws: CompanionWireError.invalid) { try CompanionPairing.confirmation(Data(repeating: 0, count: n)) } }
}
