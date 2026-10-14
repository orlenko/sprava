import CryptoKit
import Foundation
import SpravaKit
import Testing
@testable import Companion

enum WireFixtures {
    static let raw = Data((0..<32).map(UInt8.init))
    static let nonce = Data((0..<12).map(UInt8.init))
    static let id = "AAAAAAAAAAAAAAAAAAAAAA"
    static func vectors() throws -> JSONValue {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONParser.parse(Data(contentsOf: root.appendingPathComponent("companion/testdata/companion-v0-vectors.json"))).value
    }
    static func text(_ value: JSONValue?) throws -> String { try #require(value?.stringValue) }
    static func hex(_ text: String) -> Data {
        let chars = Array(text); return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
    }
}
@Test func canonicalBase64AndStrictJSONShareBrowserVectors() throws {
    let v = try WireFixtures.vectors()
    for entry in try #require(v["b64"]?["valid"]?.arrayValue) {
        let hex = try WireFixtures.text(entry["hex"]), b64 = try WireFixtures.text(entry["b64"])
        #expect(try CompanionWire.decode(b64) == WireFixtures.hex(hex))
        #expect(CompanionWire.base64(WireFixtures.hex(hex)) == b64)
    }
    for entry in try #require(v["b64"]?["invalid"]?.arrayValue) {
        let b64 = try WireFixtures.text(entry["b64"])
        #expect(throws: CompanionWireError.invalid) { try CompanionWire.decode(b64) }
    }
    for entry in try #require(v["strict-json"]?["refuse"]?.arrayValue) {
        let bytes: Data
        if let text = entry["text"]?.stringValue { bytes = Data(text.utf8) }
        else if let fill = entry["fill"] {
            let before = try WireFixtures.text(fill["before"]), after = try WireFixtures.text(fill["after"])
            let length = Int(try #require(fill["length"]?.numberValue?.safeInteger))
            bytes = Data((before + String(repeating: try WireFixtures.text(fill["repeat"]), count: length - before.utf8.count - after.utf8.count) + after).utf8)
        } else { bytes = try WireFixtures.hex(WireFixtures.text(entry["hex"])) }
        let limit = Int(entry["limit"]?.numberValue?.safeInteger ?? 1048576)
        #expect(throws: CompanionWireError.invalid) { try CompanionWire.parse(bytes, limit: limit) }
    }
    for entry in try #require(v["strict-json"]?["numbers"]?.arrayValue) {
        let text = try WireFixtures.text(entry["text"])
        let parsed = try? CompanionWire.parse(Data(text.utf8), limit: 100)
        #expect((CompanionWire.unsigned(parsed) != nil) == entry["unsigned"]?.boolValue)
    }
    let scalarKeys = try CompanionWire.parse(Data("{\"é\":1,\"e\\u0301\":2}".utf8), limit: 100)
    #expect(scalarKeys.objectValue?.entries.count == 2)
}
@Test func signedIndexMatchesIndependentNodeCipherAndSignature() throws {
    let vector = try #require(WireFixtures.vectors()["seal-index"]), plaintext = Data(try WireFixtures.text(vector["plaintext"]).utf8)
    let golden = Data(try WireFixtures.text(vector["envelope"]).utf8)
    let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: WireFixtures.raw), key = SymmetricKey(data: WireFixtures.raw)
    let bytes = try CompanionSealedObject.seal(name: "index/1", epoch: 1, key: key, plaintext: plaintext, signer: signer,
                                             nonce: AES.GCM.Nonce(data: WireFixtures.nonce))
    let generated = try CompanionWire.parse(bytes, limit: 4096), expected = try CompanionWire.parse(golden, limit: 4096)
    for field in ["v", "kid", "e", "n", "c"] { #expect(generated[field] == expected[field], "frozen field \(field)") }
    // CryptoKit randomizes Ed25519 signatures: compare ciphertext bytes and verify signatures instead.
    // https://developer.apple.com/documentation/cryptokit/curve25519/signing/privatekey/signature(for:)
    let generatedPlain = try CompanionSealedObject.open(name: "index/1", epoch: 1, key: key, bytes: bytes, owner: signer.publicKey)
    let opened = try CompanionSealedObject.open(name: "index/1", epoch: 1, key: key, bytes: golden, owner: signer.publicKey)
    #expect(CompanionWire.unsigned(opened["revision"]) == 1)
    #expect(opened["binders"]?.arrayValue?.isEmpty == true)
    #expect(generatedPlain == opened)
}
@Test func invalidOwnerAuthenticationNeverReachesDecryption() throws {
    let vector = try #require(WireFixtures.vectors()["seal-index"])
    let envelope = try CompanionWire.parse(Data(WireFixtures.text(vector["envelope"]).utf8), limit: 4096)
    let key = SymmetricKey(data: WireFixtures.raw), owner = try Curve25519.Signing.PrivateKey(rawRepresentation: WireFixtures.raw).publicKey
    var decrypts = 0
    for replacement in [JSONValue.null, .string("AA"), .string(CompanionWire.base64(Data(repeating: 0, count: 64)))] {
        var object = try #require(envelope.objectValue)
        object.entries.removeAll { $0.key == "s" }; object.entries.append(("s", replacement))
        let bytes = Data(JSONWriter.compact(.object(object)).utf8)
        #expect(throws: CompanionWireError.invalid) {
            try CompanionSealedObject.openChecked(name: "index/1", epoch: 1, key: key, bytes: bytes, owner: owner,
                decrypt: { _, _, _ in decrypts += 1; return Data("{}".utf8) })
        }
    }
    #expect(decrypts == 0)
    for (name, epoch) in [("index/2", Int64(1)), ("index/1", Int64(2))] {
        #expect(throws: CompanionWireError.invalid) {
            try CompanionSealedObject.open(name: name, epoch: epoch, key: key,
                bytes: Data(WireFixtures.text(vector["envelope"]).utf8), owner: owner)
        }
    }
}
@Test func unsignedRequestsUseFreshNoncesAndRefuseMalformedOrUnboundObjects() throws {
    let key = SymmetricKey(data: WireFixtures.raw), name = "requests/\(WireFixtures.id)/\(WireFixtures.id)", plaintext = Data("{\"seq\":1}".utf8)
    let first = try CompanionSealedObject.seal(name: name, epoch: 1, key: key, plaintext: plaintext)
    let second = try CompanionSealedObject.seal(name: name, epoch: 1, key: key, plaintext: plaintext)
    #expect(try CompanionWire.parse(first, limit: 4096)["n"] != CompanionWire.parse(second, limit: 4096)["n"])
    #expect(try CompanionWire.unsigned(CompanionSealedObject.open(name: name, epoch: 1, key: key, bytes: first)["seq"]) == 1)
    for text in ["{\"a\":1,\"a\":2}", "{\"a\":\"\\ud800\"}", "[]", "{"] {
        #expect(throws: CompanionWireError.invalid) { try CompanionSealedObject.seal(name: name, epoch: 1, key: key, plaintext: Data(text.utf8)) }
    }
    #expect(throws: CompanionWireError.invalid) { try CompanionSealedObject.open(name: name, epoch: 2, key: key, bytes: first) }
    #expect(throws: CompanionWireError.invalid) { try CompanionSealedObject.open(name: "../credentials", epoch: 1, key: key, bytes: first) }
    #expect(throws: CompanionWireError.invalid) { try CompanionSealedObject.seal(name: "index/1", epoch: 1, key: key, plaintext: plaintext) }
    #expect(throws: CompanionWireError.invalid) { try CompanionSealedObject.open(name: name, epoch: 1, key: key, bytes: Data(repeating: 0, count: 65537)) }
}
@Test func keyIDsUseExactUTF8IdentityAndUnsignedObjectsRefuseSignatureFields() throws {
    let key = SymmetricKey(data: WireFixtures.raw), signer = try Curve25519.Signing.PrivateKey(rawRepresentation: WireFixtures.raw)
    let binder = CompanionWire.base64(Data([40]) + Data(repeating: 0, count: 15)), name = "views/\(binder)/1"
    let bytes = try CompanionSealedObject.seal(name: name, epoch: 1, key: key, plaintext: Data("{}".utf8), signer: signer)
    var envelope = try #require(CompanionWire.parse(bytes, limit: 4096).objectValue)
    envelope.entries = envelope.entries.map { $0.key == "kid" ? ("kid", .string("K" + binder.dropFirst())) : $0 }
    #expect(throws: CompanionWireError.invalid) {
        try CompanionSealedObject.open(name: name, epoch: 1, key: key, bytes: Data(JSONWriter.compact(.object(envelope)).utf8), owner: signer.publicKey)
    }
    let request = "requests/\(WireFixtures.id)/\(WireFixtures.id)"
    var unsigned = try #require(CompanionWire.parse(CompanionSealedObject.seal(name: request, epoch: 1, key: key,
                                                                           plaintext: Data("{}".utf8)), limit: 4096).objectValue)
    unsigned.entries.append(("s", .null))
    #expect(throws: CompanionWireError.invalid) {
        try CompanionSealedObject.open(name: request, epoch: 1, key: key, bytes: Data(JSONWriter.compact(.object(unsigned)).utf8))
    }
}
@Test func openedPayloadRetainsOriginalAuthenticatedLengthForPaddingValidation() throws {
    let key = SymmetricKey(data: WireFixtures.raw), name = "requests/\(WireFixtures.id)/\(WireFixtures.id)"
    let plaintext = Data((" {\"seq\":1,\"pad\":\"\"}" + String(repeating: " ", count: 1005)).utf8)
    let bytes = try CompanionSealedObject.seal(name: name, epoch: 1, key: key, plaintext: plaintext)
    let opened = try CompanionSealedObject.openPayload(name: name, epoch: 1, key: key, bytes: bytes)
    #expect(opened.plaintextLength == plaintext.count)
    #expect(opened.plaintextLength != JSONWriter.compact(opened.value).utf8.count)
}
