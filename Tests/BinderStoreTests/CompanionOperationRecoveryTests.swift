import BinderFormat
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing
@testable import BinderStore

@Suite struct CompanionOperationRecoveryTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let tag = "companion:AAAAAAAAAAAAAAAAAAAAAA/BBBBBBBBBBBBBBBBBBBBBA"
    let user = JSONObject([("kind", .str("user")), ("client", .str("sprava/0.1"))])
    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0"), store = TekaStore(folder: folder)
        store.testHookFullSync = { _ in 0 }
        try store.adopt(survey: JSONObject(), owner: JSONObject([("device", .str("test"))]), now: now)
        return (folder, store)
    }
    func body(_ note: String?) -> TekaStore.OpBody {
        .init(op: "dismiss", args: JSONObject([("id", .str("estate-example-2026-007"))]), actor: user,
              extra: note.map { [("note", .string($0))] } ?? [])
    }
    func items(_ folder: URL) throws -> [JSONValue] {
        try #require(try JSONParser.parse(Data(contentsOf: folder.appendingPathComponent("catalog.json"))).value["open_items"]?.arrayValue)
    }
    func dismissed(_ folder: URL) throws -> Bool {
        try items(folder).first { $0["id"] == .str("estate-example-2026-007") }?["dismissed"] == .bool(true)
    }

    @Test func aTaggedLoggedWriteBeforeRenameIsAbortedAndNeverRolledForwardOrRepeated() throws {
        let (folder, store) = try adopted(); defer { try? FileManager.default.removeItem(at: folder) }
        struct Crash: Error {}
        store.testHookAfterAppend = { throw Crash() }
        #expect(throws: Crash.self) { try store.apply([body(tag)], now: now) }
        let effect = try #require(try store.readOpLog().ops.last?["id"]?.stringValue)
        #expect(throws: (any Error).self) { try store.companionOperationProof(effectID: effect, tag: tag) }
        store.testHookAfterAppend = nil; try store.settle(now: now)
        #expect(store.lastAbsorbed == .aborted(1))
        #expect(try dismissed(folder) == false)
        let last = try #require(try store.readOpLog().ops.last)
        #expect(last["op"] == .str("abort") && last["args"]?["reason"] == .str("companion-review"))
        #expect(last["args"]?["ops"] == .array([.string(effect)]))
        #expect(try store.companionOperationProof(effectID: effect, tag: tag) == .unknown)
        try store.settle(now: now)
        #expect(try store.readOpLog().ops.filter { $0["op"] == .str("abort") }.count == 1)
        #expect(try dismissed(folder) == false)
    }

    @Test func aTaggedAppliedWriteWhoseCatalogAndSnapshotWereRestoredIsAlsoUnknown() throws {
        let (folder, store) = try adopted(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        let snapshot = try Data(contentsOf: folder.appendingPathComponent(".sprava/snapshot.json"))
        let effect = try #require(try store.apply([body(tag)], now: now).first?["id"]?.stringValue)
        try catalog.write(to: folder.appendingPathComponent("catalog.json")); try snapshot.write(to: folder.appendingPathComponent(".sprava/snapshot.json"))
        try store.settle(now: now)
        #expect(try dismissed(folder) == false)
        #expect(try store.companionOperationProof(effectID: effect, tag: tag) == .unknown)
    }

    @Test func untaggedAndNoncanonicalTagWritesStillRollForwardExactlyAsBefore() throws {
        for note in [nil, "An invented note", "companion:AAAAAAAAAAAAAAAAAAAAAA/BBBBBBBBBBBBBBBBBBBBBB"] as [String?] {
            let (folder, store) = try adopted(); defer { try? FileManager.default.removeItem(at: folder) }
            struct Crash: Error {}
            store.testHookAfterAppend = { throw Crash() }
            #expect(throws: Crash.self) { try store.apply([body(note)], now: now) }
            store.testHookAfterAppend = nil; try store.settle(now: now)
            #expect(store.lastAbsorbed == .rolledForward(1))
            #expect(try dismissed(folder))
        }
    }

    @Test func onlyACompleteUnabortedWriteAfterRecoveryIsProofAndTheFacadeWritesNothing() throws {
        let (folder, store) = try adopted(); defer { try? FileManager.default.removeItem(at: folder) }
        let effect = try #require(try store.apply([body(tag)], now: now).first?["id"]?.stringValue)
        let logURL = folder.appendingPathComponent(".sprava/ops.ndjson"), before = try Data(contentsOf: logURL)
        #expect(try store.companionOperationProof(effectID: effect, tag: tag) == .tookEffect)
        #expect(try store.companionOperationProof(effectID: "019a2000-0000-7000-8000-000000000003", tag: tag) == .notApplied)
        #expect(try Data(contentsOf: logURL) == before)
        // A record only in a torn tail is proven not applied: the writer logs before any catalog rename.
        let absent = "019a2000-0000-7000-8000-000000000004"
        let handle = try FileHandle(forWritingTo: logURL); try handle.seekToEnd(); try handle.write(contentsOf: Data(("{\"id\":\"" + absent + "\"").utf8)); try handle.close()
        #expect(try store.companionOperationProof(effectID: absent, tag: tag) == .notApplied)
        #expect(try store.companionOperationProof(effectID: effect, tag: tag) == .tookEffect)
    }
}
