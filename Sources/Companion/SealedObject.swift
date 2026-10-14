import CryptoKit
import Foundation
import SpravaKit

public struct CompanionOpenedObject {
    public let value: JSONValue
    /// Authenticated byte length, including original whitespace; payload padding must use this, never reserialization.
    public let plaintextLength: Int
}
/// Envelope authentication only. Payload schemas, durable admission and request effects belong to their callers.
public enum CompanionSealedObject {
    struct Binding { let kid: String; let signed: Bool; let plaintext: Int; let wire: Int }
    static func binding(_ name: String, _ epoch: Int64) throws -> Binding {
        guard epoch >= 0, epoch <= JSONNumber.maxSafeInteger else { throw CompanionWireError.invalid }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        func revision(_ text: String) -> Bool {
            guard let n = Int64(text), n >= 1, n <= JSONNumber.maxSafeInteger else { return false }
            return String(n) == text
        }
        if parts.count == 2, parts[0] == "index", revision(parts[1]), epoch >= 1 {
            return Binding(kid: "account", signed: true, plaintext: 92700, wire: 1048576)
        }
        if parts.count == 3, parts[0] == "views", CompanionWire.isID(parts[1]), revision(parts[2]), epoch >= 1 {
            return Binding(kid: parts[1], signed: true, plaintext: 778240, wire: 1048576)
        }
        if parts.count == 3, parts[0] == "pairings", CompanionWire.isID(parts[1]) {
            if parts[2] == "hello", epoch == 0 { return Binding(kid: "wrap", signed: false, plaintext: 512, wire: 2048) }
            if parts[2] == "key", epoch >= 1 { return Binding(kid: "wrap", signed: false, plaintext: 227, wire: 1024) }
        }
        if parts.count == 4, parts[0] == "devices", CompanionWire.isID(parts[1]), revision(parts[3]) {
            if parts[2] == "keys", epoch >= 1, parts[3] == String(epoch) {
                return Binding(kid: "device", signed: true, plaintext: 123, wire: 4096)
            }
            if parts[2] == "outcomes", epoch == 0 { return Binding(kid: "device", signed: true, plaintext: 256512, wire: 524288) }
        }
        if parts.count == 3, parts[0] == "devices", CompanionWire.isID(parts[1]), parts[2] == "revocation", epoch == 0 {
            return Binding(kid: "device", signed: false, plaintext: 4096, wire: 4096)
        }
        if parts.count == 3, parts[0] == "requests", CompanionWire.isID(parts[1]), CompanionWire.isID(parts[2]), epoch >= 1 {
            return Binding(kid: "device", signed: false, plaintext: 48128, wire: 65536)
        }
        throw CompanionWireError.invalid
    }
    static func aad(_ name: String, _ binding: Binding, _ epoch: Int64) -> Data {
        Data("sprava-companion/v0|\(name)|\(binding.kid)|\(epoch)".utf8)
    }
    static func signedBytes(_ name: String, _ binding: Binding, _ epoch: Int64, _ nonce: Data, _ ciphertext: Data) -> Data {
        Data("sprava-companion/v0 signed|\(name)|\(binding.kid)|\(epoch)|".utf8) + nonce + ciphertext
    }
    public static func seal(name: String, epoch: Int64, key: SymmetricKey, plaintext: Data,
                            signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        try seal(name: name, epoch: epoch, key: key, plaintext: plaintext, signer: signer, nonce: AES.GCM.Nonce())
    }
    // Deterministic nonces are internal for frozen vectors; production callers always get a fresh nonce.
    static func seal(name: String, epoch: Int64, key: SymmetricKey, plaintext: Data,
                     signer: Curve25519.Signing.PrivateKey?, nonce: AES.GCM.Nonce) throws -> Data {
        do {
            let b = try binding(name, epoch)
            guard key.bitCount == 256, (signer != nil) == b.signed,
                  try CompanionWire.parse(plaintext, limit: b.plaintext).objectValue != nil else { throw CompanionWireError.invalid }
            let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad(name, b, epoch))
            let n = nonce.withUnsafeBytes { Data($0) }, c = box.ciphertext + box.tag
            var fields: [(key: String, value: JSONValue)] = [
                ("v", .number(JSONNumber(text: "0"))), ("kid", .string(b.kid)), ("e", .number(JSONNumber(text: String(epoch)))),
                ("n", .string(CompanionWire.base64(n))), ("c", .string(CompanionWire.base64(c))) ]
            if let signer { fields.append(("s", .string(CompanionWire.base64(try signer.signature(for: signedBytes(name, b, epoch, n, c)))))) }
            let bytes = Data(JSONWriter.compact(.object(JSONObject(fields))).utf8)
            guard bytes.count <= b.wire else { throw CompanionWireError.invalid }; return bytes
        } catch { throw CompanionWireError.invalid }
    }
    public static func open(name: String, epoch: Int64, key: SymmetricKey, bytes: Data,
                            owner: Curve25519.Signing.PublicKey? = nil) throws -> JSONValue {
        try openPayload(name: name, epoch: epoch, key: key, bytes: bytes, owner: owner).value
    }
    public static func openPayload(name: String, epoch: Int64, key: SymmetricKey, bytes: Data,
                                  owner: Curve25519.Signing.PublicKey? = nil) throws -> CompanionOpenedObject {
        try openChecked(name: name, epoch: epoch, key: key, bytes: bytes, owner: owner,
                        decrypt: { try AES.GCM.open($0, using: $1, authenticating: $2) })
    }
    // The seam proves in tests that a rejected owner signature never reaches decryption.
    static func openChecked(name: String, epoch: Int64, key: SymmetricKey, bytes: Data, owner: Curve25519.Signing.PublicKey?,
                            decrypt: (AES.GCM.SealedBox, SymmetricKey, Data) throws -> Data) throws -> CompanionOpenedObject {
        do {
            let b = try binding(name, epoch), envelope = try CompanionWire.parse(bytes, limit: b.wire)
            guard key.bitCount == 256, envelope.objectValue != nil, CompanionWire.unsigned(envelope["v"]) == 0,
                  let kid = envelope["kid"]?.stringValue, kid.utf8.elementsEqual(b.kid.utf8), CompanionWire.unsigned(envelope["e"]) == epoch,
                  let nText = envelope["n"]?.stringValue, let cText = envelope["c"]?.stringValue else { throw CompanionWireError.invalid }
            let n = try CompanionWire.decode(nText), c = try CompanionWire.decode(cText)
            guard n.count == 12, c.count >= 16, c.count <= b.plaintext + 16 else { throw CompanionWireError.invalid }
            if b.signed {
                guard let owner, let sText = envelope["s"]?.stringValue else { throw CompanionWireError.invalid }
                let signature = try CompanionWire.decode(sText)
                guard signature.count == 64, owner.isValidSignature(signature, for: signedBytes(name, b, epoch, n, c)) else {
                    throw CompanionWireError.invalid
                }
            } else if envelope.objectValue!.contains("s") { throw CompanionWireError.invalid }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: n), ciphertext: c.dropLast(16), tag: c.suffix(16))
            let plaintext = try decrypt(box, key, aad(name, b, epoch)), value = try CompanionWire.parse(plaintext, limit: b.plaintext)
            guard value.objectValue != nil else { throw CompanionWireError.invalid }
            return CompanionOpenedObject(value: value, plaintextLength: plaintext.count)
        } catch { throw CompanionWireError.invalid }
    }
}
