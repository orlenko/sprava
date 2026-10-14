import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private let requestDevice = CompanionWire.base64(Data(repeating: 51, count: 16))
private let requestID = CompanionWire.base64(Data(repeating: 52, count: 16))
private let requestBinder = CompanionWire.base64(Data(repeating: 53, count: 16))
private final class RequestSecrets: CompanionCredentialStorage, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
}
private struct RequestFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-request-" + UUID().uuidString)
    let secrets = RequestSecrets()
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    let key = SymmetricKey(data: Data(repeating: 54, count: 32))
    func prepare() throws -> CompanionProfile {
        let p = try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets)
        _ = try p.prepareAccount()
        try p.store.write { try $0.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'active', 0, 1, 0)", .text(requestDevice)) }
        _ = try secrets.insert(account: p.deviceAccount(requestDevice), bytes: key.withUnsafeBytes { Data($0) })
        return p
    }
    // Independently encrypt arbitrary plaintext so strict-JSON failures are tested after authentication.
    func sealed(_ plaintext: Data, epoch: Int64 = 1, id: String = requestID) throws -> Data {
        let name = "requests/\(requestDevice)/\(id)", nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce,
            authenticating: Data("sprava-companion/v0|\(name)|device|\(epoch)".utf8))
        return Data(JSONWriter.compact(.object(JSONObject([
            ("v", .number(JSONNumber(text: "0"))), ("kid", .string("device")), ("e", .number(JSONNumber(text: String(epoch)))),
            ("n", .string(CompanionWire.base64(nonce.withUnsafeBytes { Data($0) }))),
            ("c", .string(CompanionWire.base64(box.ciphertext + box.tag)))
        ]))).utf8)
    }
}
private func action(_ kind: String = "done", item: JSONValue = .number(JSONNumber(text: "-7"))) -> JSONObject {
    var fields: [(key: String, value: JSONValue)] = [("seq", .number(JSONNumber(text: "2"))), ("type", .string(kind)),
        ("made_at", .string("2026-10-15T12:00:00Z")), ("binder", .string(requestBinder))]
    if kind == "note" { fields.append(("text", .string("An invented note\nwith a tab\t"))) }
    else {
        fields += [("item", item), ("seen_version", .number(JSONNumber(text: "1")))]
        if kind == "follow_up" || kind == "postpone" { fields.append(("date", .string("2026-10-16"))) }
    }
    return JSONObject(fields)
}
private func pad(_ object: JSONObject, whitespace: Bool = false) -> Data {
    var fields = object.entries.filter { $0.key != "pad" }
    fields.append(("pad", .string("")))
    let plain = JSONWriter.compact(.object(JSONObject(fields))), count = plain.utf8.count
    let target = ((count + 1023) / 1024) * 1024
    if whitespace { return Data((plain + String(repeating: " ", count: target - count)).utf8) }
    fields[fields.count - 1] = ("pad", .string(String(repeating: " ", count: target - count)))
    return Data(JSONWriter.compact(.object(JSONObject(fields))).utf8)
}
private func replacing(_ object: JSONObject, _ name: String, _ value: JSONValue?) -> JSONObject {
    var fields = object.entries.filter { $0.key != name }; if let value { fields.append((name, value)) }; return JSONObject(fields)
}
private func opened(_ admission: CompanionRequestAdmission) throws -> CompanionAuthenticatedRequest {
    guard case .authenticated(let request) = admission else { throw CompanionWireError.invalid }; return request
}
private func discarded(_ admission: CompanionRequestAdmission) -> CompanionRequestAdmission.Discard? {
    if case .discarded(let reason) = admission { return reason }; return nil
}

@Test func everyActionKeepsItsTypedItemAndDateAndUnknownFieldsAreIgnoredAfterAuthentication() throws {
    let f = RequestFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    for kind in ["done", "drop", "arrived", "follow_up", "postpone", "note"] {
        let payload = replacing(action(kind), "unknown", .bool(true))
        let request = try opened(p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: f.sealed(pad(payload))))
        #expect(request.sequence == 2 && request.epoch == 1 && request.deviceID == requestDevice && request.requestID == requestID)
        #expect(request.action?.kind.rawValue == kind && request.action?.binderID == requestBinder)
        if kind == "note" { #expect(request.action?.text == "An invented note\nwith a tab\t" && request.action?.itemID == nil) }
        else { #expect(request.action?.itemID == .number(JSONNumber(text: "-7")) && request.action?.seenVersion == 1) }
    }
    let request = try opened(p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: f.sealed(pad(action(item: .string("7"))))))
    #expect(request.action?.itemID == .string("7"))
    #expect(try p.store.read { try $0.rows("SELECT highest_seq FROM devices") } == [[.integer(0)]])
}

@Test func unauthenticatedBodiesAndUnknownDevicesAreDiscardedButLocalKeyFailuresRemainRetryable() throws {
    let f = RequestFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let bytes = try f.sealed(pad(action()))
    #expect(discarded(try p.admitRequest(deviceID: "../private", requestID: requestID, bytes: bytes)) == .badID)
    #expect(discarded(try p.admitRequest(deviceID: requestBinder, requestID: requestID, bytes: bytes)) == .notActive)
    #expect(discarded(try p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: Data(repeating: 0, count: 65537))) == .tooLarge)
    #expect(discarded(try p.admitRequest(deviceID: requestDevice, requestID: requestBinder, bytes: bytes)) == .unreadable)
    #expect(discarded(try p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: f.sealed(pad(action()), epoch: 2))) == .unreadable)
    f.secrets.values.removeValue(forKey: p.deviceAccount(requestDevice))
    #expect(throws: CompanionCredentialError.unavailable) { try p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: bytes) }
    try p.store.write { try $0.execute("UPDATE devices SET state = 'revoked'") }
    #expect(discarded(try p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: bytes)) == .notActive)
}

@Test func invalidStrictPayloadsAndSequencesAreDiscardedAfterDecryptButInvalidActionsKeepTheirSequence() throws {
    let f = RequestFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    for text in ["{", "[]", "{\"seq\":1,\"seq\":2}", "{\"seq\":0}", "{\"seq\":1e0}", "{\"seq\":-1}", "{\"seq\":9007199254740992}", "{\"seq\":1,\"text\":\"\\ud800\"}"] {
        #expect(discarded(try p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: f.sealed(Data(text.utf8)))) == .noSequence)
    }
    for payload in [replacing(action(), "type", .string("execute")), replacing(action(), "made_at", .string("tomorrow")),
                    replacing(action(), "binder", nil), replacing(action(), "item", .number(JSONNumber(text: "0"))),
                    replacing(action(), "seen_version", .number(JSONNumber(text: "0"))), replacing(action(), "text", .string("extra")),
                    replacing(action("postpone"), "date", .string("20261016")), replacing(action("note"), "text", .string("bad\u{01}")),
                    replacing(action("note"), "text", .string(String(repeating: "x", count: 10001)))] {
        let request = try opened(p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: f.sealed(pad(payload))))
        #expect(request.sequence == 2 && request.action == nil)
    }
}

@Test func requestPaddingUsesTheOriginalAuthenticatedLengthAndAllOlderPositiveEpochsStillOpen() throws {
    let f = RequestFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let whitespace = try opened(p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: f.sealed(pad(action(), whitespace: true))))
    #expect(whitespace.action != nil)
    let unpadded = Data(JSONWriter.compact(.object(replacing(action(), "pad", .string("")))).utf8)
    #expect(try opened(p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: f.sealed(unpadded))).action == nil)
    let badPad = replacing(action(), "pad", .string("not spaces"))
    #expect(try opened(p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: f.sealed(Data(JSONWriter.compact(.object(badPad)).utf8)))).action == nil)
    let validPadded = pad(action()), paddedObject = try #require(CompanionWire.parse(validPadded, limit: 48128).objectValue)
    let spaces = try #require(paddedObject["pad"]?.stringValue)
    let sameLengthBadPad = Data(JSONWriter.compact(.object(replacing(paddedObject, "pad", .string("x" + spaces.dropFirst())))).utf8)
    #expect(sameLengthBadPad.count == validPadded.count)
    #expect(try opened(p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: f.sealed(sameLengthBadPad))).action == nil)
    try p.store.write { try $0.execute("UPDATE profile SET epoch = 2") }
    let old = try opened(p.admitRequest(deviceID: requestDevice, requestID: requestID, bytes: f.sealed(pad(action()), epoch: 1)))
    #expect(old.epoch == 1 && old.action != nil)
}
