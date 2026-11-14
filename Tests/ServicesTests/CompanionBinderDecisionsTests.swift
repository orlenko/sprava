import BinderFormat
import BinderStore
import Capture
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing
@testable import Companion
@testable import Services

private final class DecisionSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
}
/// Accepts every upload, as the relay does after a `204`.
private actor AcceptingTarget: CompanionPublishingTarget {
    let profile: CompanionProfile
    init(_ profile: CompanionProfile) { self.profile = profile }
    func uploadView(binderID: String) async throws -> CompanionPublicationProgress {
        guard let view = try profile.pendingView(binderID: binderID) else { return .idle }
        try profile.completeView(view); return .uploaded(name: view.name)
    }
    func uploadIndex(generatedAt: String) async throws -> CompanionPublicationProgress {
        let index = try profile.pendingIndex() ?? profile.prepareIndex(generatedAt: generatedAt)
        try profile.completeIndex(index); return .uploaded(name: index.name)
    }
    func cleanRemovedBinders(limit: Int) async throws -> Int { 0 }
}
private struct Crash: Error {}
/// The real adapter, stopped right after the decision record was written (`afterApply` false) or right after its
/// effect was written (true), as a crash would stop it.
private struct CrashingDecisions: CompanionDecisionAdapter {
    let real: CompanionBinderDecisions
    let afterApply: Bool
    func withPreparedDecision<Result>(for request: CompanionAuthenticatedRequest,
        _ body: (CompanionDecisionPlan, (CompanionDecisionRecord) throws -> Void) throws -> Result) throws -> Result {
        try real.withPreparedDecision(for: request) { plan, apply in
            try withoutActuallyEscaping(apply) { apply in
                try body(plan) { record in if afterApply { try apply(record) }; throw Crash() }
            }
        }
    }
    func withRecoveredDecision<Result>(for record: CompanionDecisionRecord,
        _ body: (CompanionDecisionProof, (CompanionDecisionRecord) throws -> Void) throws -> Result) throws -> Result {
        try real.withRecoveredDecision(for: record, body)
    }
}

private let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
private let morning = Date(timeIntervalSince1970: 1_794_560_400) // 2026-11-13T09:00:00Z
private let mac = "019a2000-0000-7000-8000-0000000000a1"
private let phone = CompanionWire.base64(Data(repeating: 41, count: 16))
private func requestID(_ n: UInt8) -> String { CompanionWire.base64(Data(repeating: n, count: 16)) }

/// An invented support folder, a claimed relay, one paired phone and one adopted binder this Mac owns, shown on the
/// phone and published once (version 1).
private struct DecisionFixture {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-decisions-" + UUID().uuidString)
    let secrets = DecisionSecrets()
    let binder: URL
    var binderID = ""

    init(publish: Bool = true) async throws {
        binder = try makeTeka(fixture: "sprava-v0", folderName: "invented-estate")
        try TekaStore(folder: binder).adopt(survey: JSONObject(), owner: JSONObject([("device", .string(mac))]), now: morning)
        try ShelfStore(supportDirectory: support).add(binder)
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 31, count: 32).base64EncodedString())
        let p = try profile()
        _ = try p.prepareAccount()
        try p.store.write { t in
            try t.execute("UPDATE profile SET claim_state = 'claimed' WHERE slot = 1")
            try t.execute("INSERT INTO devices (device, state, key_ready, creation_attempted, cleanup_pending, local_deadline) " +
                          "VALUES (?, 'active', 0, 1, 0, '2099-01-01T00:00:00Z')", .text(phone))
            try t.execute("INSERT INTO pairings (device, pairing, expires, label, paired_at, acknowledged, key_epoch, wrapped_key, device_keys) " +
                          "VALUES (?, ?, '2099-01-01T00:00:00Z', 'Invented phone', '2026-11-13T08:00:00Z', 1, 1, ?, ?)",
                          .text(phone), .text(requestID(42)), .blob(Data([1])), .blob(Data([2])))
        }
        guard publish else { return }
        binderID = try p.showBinder(try CompanionBinderIdentities(support: support).identity(for: binder)).id
        _ = try await CompanionPublishing(support: support, deviceID: mac).run(profile: p, target: AcceptingTarget(p),
            rows: ShelfStore(supportDirectory: support).rowsForJobs(), now: morning, timeZone: utc)
    }
    func profile() throws -> CompanionProfile { try CompanionProfile(database: support.appendingPathComponent("companion/state.sqlite"), relay: relay, secrets: secrets) }
    func decisions() throws -> CompanionBinderDecisions {
        CompanionBinderDecisions(profile: try profile(), support: support, deviceID: mac, timeZone: utc, clock: { morning })
    }
    func request(_ kind: CompanionRequestedAction.Kind, item: String? = nil, date: String? = nil, text: String? = nil,
                 binder: String? = nil, r: UInt8 = 50, seq: Int64 = 1) -> CompanionAuthenticatedRequest {
        CompanionAuthenticatedRequest(deviceID: phone, requestID: requestID(r), epoch: 1, sequence: seq,
            action: CompanionRequestedAction(kind: kind, madeAt: "2026-11-13T08:59:00Z", binderID: binder ?? (kind == .note ? nil : binderID),
                itemID: item.map(JSONValue.string), seenVersion: kind == .note ? nil : 1, date: date, text: text))
    }
    func decide(_ request: CompanionAuthenticatedRequest, adapter: (any CompanionDecisionAdapter)? = nil) throws -> CompanionExecutedDecision {
        try CompanionDecisionExecution(profile: profile()).decide(request, today: "2026-11-13", now: "2026-11-13T09:00:00Z",
                                                                 adapter: adapter ?? decisions())
    }
    func openIDs() -> [String] { (Teka.read(binder).catalog?["open_items"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue } }
    func tagged(_ request: CompanionAuthenticatedRequest) throws -> [JSONObject] {
        try TekaStore(folder: binder).readOpLog().ops.filter { $0["note"] == .string(CompanionBinderDecisions.tag(request)) }
    }
    func notes() throws -> [URL] {
        let folder = CaptureInbox.defaultRoot(support: support).appendingPathComponent(mac)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }
    func remove() { try? FileManager.default.removeItem(at: support); try? FileManager.default.removeItem(at: binder.deletingLastPathComponent()) }
}

@Test func doneFromThePhoneClosesTheItemAsThePersonsOwnChangeWithUndo() async throws {
    let f = try await DecisionFixture(); defer { f.remove() }
    let request = f.request(.done, item: "estate-example-2026-007")
    let decision = try f.decide(request)
    #expect(decision.committed && decision.outcome.outcome == .applied)
    #expect(!f.openIDs().contains("estate-example-2026-007"))
    let op = try #require(try f.tagged(request).first)
    #expect(op["op"] == .str("complete") && op["actor"]?["kind"] == .str("user") && op["args"]?["source"] == .str("user"))
    // Undo reopens it under a new id with every field it had (binder-v0 §6.10).
    _ = try TekaStore(folder: f.binder).undoChange(opID: try #require(op["id"]?.stringValue), now: morning.addingTimeInterval(60))
    let items = Teka.read(f.binder).catalog?["open_items"]?.arrayValue ?? []
    #expect(items.contains { $0["title"] == .str("File the estate inventory with the notary") && $0["due"] == .str("2026-10-10") })
}

@Test func followUpAndPostponeChangeOnlyTheirDate() async throws {
    let f = try await DecisionFixture(); defer { f.remove() }
    #expect(try f.decide(f.request(.followUp, item: "estate-example-2026-008", date: "2026-11-20")).outcome.outcome == .applied)
    #expect(try f.decide(f.request(.postpone, item: "estate-example-2026-007", date: "2026-11-27", r: 51, seq: 2)).outcome.outcome == .applied)
    let items = Teka.read(f.binder).catalog?["open_items"]?.arrayValue ?? []
    let waiting = try #require(items.first { $0["id"] == .str("estate-example-2026-008") })
    #expect(waiting["follow_up_at"] == .str("2026-11-20") && waiting["status"] == .str("waiting") && waiting["due"] == .str("2026-10-31"))
    #expect(items.first { $0["id"] == .str("estate-example-2026-007") }?["due"] == .str("2026-11-27"))
}

@Test func aStaleDoneBecomesOneTrustedCardThatChangesNothingUntilApproved() async throws {
    let f = try await DecisionFixture(); defer { f.remove() }
    // The person edits the item on the Mac after the phone's view was published.
    try TekaStore(folder: f.binder).apply([TekaStore.OpBody(op: "update_item",
        args: JSONObject([("id", .str("estate-example-2026-007")), ("set", .obj([("priority", .str("normal"))]))]),
        actor: JSONObject([("kind", .str("user"))]))], now: morning)
    let request = f.request(.done, item: "estate-example-2026-007")
    #expect(try f.decide(request).outcome.outcome == .conflict)
    #expect(f.openIDs().contains("estate-example-2026-007"))
    #expect(try f.tagged(request).isEmpty)
    let id = CompanionConflictCard.id(device: phone, request: requestID(50))
    let commands = Commands(support: f.support, deviceID: mac)
    #expect(commands.isTrusted(id, in: f.binder))
    let card = try commands.loadTrusted(id, in: f.binder)
    #expect(card.title.contains("Invented phone") && card.title.contains("changed since your phone saw it"))
    #expect(card.ops.first?["op"] == .str("complete"))
    // The same request again decides nothing new and writes no second card.
    #expect(!(try f.decide(request)).committed)
    #expect(ProposalStore.list(in: f.binder).filter { $0.0.id == id }.count == 1)
    // Approving it runs the binder's guard as for any card.
    try TekaStore(folder: f.binder).approve(card, now: morning.addingTimeInterval(60))
    #expect(!f.openIDs().contains("estate-example-2026-007"))
}

@Test func doneOnARepeatingItemWaitsForThePerson() async throws {
    let f = try await DecisionFixture(); defer { f.remove() }
    #expect(try f.decide(f.request(.done, item: "estate-example-2026-010")).outcome.outcome == .conflict)
    #expect(f.openIDs().contains("estate-example-2026-010"))
    let card = try Commands(support: f.support, deviceID: mac).loadTrusted(CompanionConflictCard.id(device: phone, request: requestID(50)), in: f.binder)
    #expect(card.title.contains("repeating"))
}

@Test func aRequestForABinderNotShownIsRejectedAndOneAwayForNowWaits() async throws {
    let f = try await DecisionFixture(); defer { f.remove() }
    let unknown = f.request(.done, item: "estate-example-2026-007", binder: requestID(60))
    #expect(try f.decide(unknown).outcome.outcome == .rejected)
    let away = f.binder.deletingLastPathComponent().appendingPathComponent("invented-estate-offloaded", isDirectory: true)
    try FileManager.default.moveItem(at: f.binder, to: away)
    #expect(throws: CompanionDeviceDecisionFailure.self) { try f.decide(f.request(.done, item: "estate-example-2026-007", r: 51, seq: 2)) }
    #expect(try f.profile().pendingDecision(deviceID: phone) == nil)
    try FileManager.default.moveItem(at: away, to: f.binder)
    try f.profile().hideBinder(try CompanionBinderIdentities(support: f.support).identity(for: f.binder))
    #expect(try f.decide(f.request(.done, item: "estate-example-2026-007", r: 51, seq: 2)).outcome.outcome == .rejected)
    #expect(f.openIDs().contains("estate-example-2026-007"))
}

@Test func aCrashBetweenIntentAndApplyIsDecidedAgainAndAppliedOnce() async throws {
    let f = try await DecisionFixture(); defer { f.remove() }
    let request = f.request(.done, item: "estate-example-2026-007")
    #expect(throws: Crash.self) { try f.decide(request, adapter: CrashingDecisions(real: try f.decisions(), afterApply: false)) }
    #expect(f.openIDs().contains("estate-example-2026-007"))
    let recovered = try #require(try CompanionDecisionExecution(profile: f.profile()).recoverPending(deviceID: phone,
        today: "2026-11-13", now: "2026-11-13T09:01:00Z", adapter: f.decisions()))
    #expect(recovered.committed && recovered.outcome.outcome == .applied)
    #expect(!f.openIDs().contains("estate-example-2026-007"))
    #expect(try f.tagged(request).count == 1)
}

@Test func aCrashAfterTheOpWasWrittenCommitsItWithoutApplyingItAgain() async throws {
    let f = try await DecisionFixture(); defer { f.remove() }
    let request = f.request(.done, item: "estate-example-2026-007")
    #expect(throws: Crash.self) { try f.decide(request, adapter: CrashingDecisions(real: try f.decisions(), afterApply: true)) }
    #expect(!f.openIDs().contains("estate-example-2026-007"))
    let recovered = try #require(try CompanionDecisionExecution(profile: f.profile()).recoverPending(deviceID: phone,
        today: "2026-11-13", now: "2026-11-13T09:01:00Z", adapter: f.decisions()))
    #expect(recovered.committed && recovered.outcome.outcome == .applied)
    #expect(try f.tagged(request).count == 1)
}

@Test func anOpThatMayOrMayNotHaveTakenEffectBecomesACardAndIsNeverAppliedAgain() async throws {
    let f = try await DecisionFixture(); defer { f.remove() }
    let catalog = f.binder.appendingPathComponent("catalog.json"), snapshot = f.binder.appendingPathComponent(".sprava/snapshot.json")
    let before = (try Data(contentsOf: catalog), try Data(contentsOf: snapshot))
    let request = f.request(.done, item: "estate-example-2026-007")
    #expect(throws: Crash.self) { try f.decide(request, adapter: CrashingDecisions(real: try f.decisions(), afterApply: true)) }
    // The op was logged, and the binder now reads as it did before it: the Mac cannot tell which happened (§9.6).
    try before.0.write(to: catalog); try before.1.write(to: snapshot)
    let recovered = try #require(try CompanionDecisionExecution(profile: f.profile()).recoverPending(deviceID: phone,
        today: "2026-11-13", now: "2026-11-13T09:01:00Z", adapter: f.decisions()))
    #expect(recovered.outcome.outcome == .conflict)
    #expect(f.openIDs().contains("estate-example-2026-007"))
    let card = try Commands(support: f.support, deviceID: mac).loadTrusted(CompanionConflictCard.id(device: phone, request: requestID(50)), in: f.binder)
    #expect(card.title.contains("stopped in the middle"))
}

@Test func aNoteIsWrittenOnceEvenAfterACrashNamingTheShownBinder() async throws {
    let f = try await DecisionFixture(); defer { f.remove() }
    let request = f.request(.note, text: "Invented note from the phone", binder: f.binderID)
    #expect(throws: Crash.self) { try f.decide(request, adapter: CrashingDecisions(real: try f.decisions(), afterApply: true)) }
    #expect(try f.notes().count == 1)
    let recovered = try #require(try CompanionDecisionExecution(profile: f.profile()).recoverPending(deviceID: phone,
        today: "2026-11-13", now: "2026-11-13T09:01:00Z", adapter: f.decisions()))
    #expect(recovered.outcome.outcome == .applied)
    #expect(!(try f.decide(request)).committed)
    let notes = try f.notes()
    #expect(notes.count == 1)
    let event = try JSONParser.parse(try Data(contentsOf: try #require(notes.first))).value
    #expect(event["binder_hint"] == .str("estate-example") && event["extensions"]?["sprava"]?["companion"]?["request_id"] == .string(requestID(50)))
}

/// One phone's mailbox on the relay: lists what it holds, serves the sealed bodies, deletes what the Mac decided.
private actor Mailbox: RequestCollectionTransport {
    var bodies: [String: Data]
    var deleted: [String] = []
    init(_ bodies: [String: Data]) { self.bodies = bodies }
    func listRequests(deviceID: String, after: Int64?, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestPage> {
        let listed = bodies.keys.sorted().enumerated().map { CompanionListedRequest(requestID: $0.element, ordinal: Int64($0.offset + 1),
                                                                                     receivedAt: "2026-11-13T08:59:30Z") }
        return CompanionRelayReply(status: 200, value: CompanionRequestPage(requests: listed, next: nil), receivedBytes: 100)
    }
    func fetchRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestDownload> {
        guard let bytes = bodies[requestID] else { return CompanionRelayReply(status: 404, value: nil, receivedBytes: 0) }
        return CompanionRelayReply(status: 200, value: .body(bytes), receivedBytes: bytes.count)
    }
    func deleteRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<Data> {
        bodies[requestID] = nil; deleted.append(requestID)
        return CompanionRelayReply(status: 204, value: nil, receivedBytes: 0)
    }
}
private actor OutcomesRelay: CompanionOutcomesTarget {
    let profile: CompanionProfile
    var published: [String] = []
    init(_ profile: CompanionProfile) { self.profile = profile }
    func uploadOutcomes(deviceID: String, generatedAt: String) async throws -> CompanionPublicationProgress {
        guard let outcomes = try profile.prepareOutcomes(deviceID: deviceID, generatedAt: generatedAt) else { return .idle }
        try profile.completeOutcomes(outcomes); published.append(deviceID); return .uploaded(name: outcomes.name)
    }
}

@Test func theJobsDrainDecidesAPhonesDoneDeletesItAndPublishesItsOutcome() async throws {
    let f = try await DecisionFixture(); defer { f.remove() }
    let p = try f.profile(), key = Data(repeating: 43, count: 32)
    _ = try p.secrets.insert(account: p.deviceAccount(phone), bytes: key)
    let fields: [(String, JSONValue)] = [("type", .str("done")), ("seq", .number(JSONNumber(text: "1"))), ("made_at", .str("2026-11-13T08:59:00Z")),
        ("binder", .string(f.binderID)), ("item", .str("estate-example-2026-007")), ("seen_version", .number(JSONNumber(text: "1")))]
    let size = JSONWriter.compact(.obj(fields + [("pad", .str(""))])).utf8.count
    let plaintext = Data(JSONWriter.compact(.obj(fields + [("pad", .string(String(repeating: " ", count: 1024 - size)))])).utf8)
    let sealed = try CompanionSealedObject.seal(name: "requests/\(phone)/\(requestID(50))", epoch: 1, key: .init(data: key), plaintext: plaintext)
    let mailbox = Mailbox([requestID(50): sealed]), outcomes = OutcomesRelay(p)
    let draining = CompanionDraining(support: f.support, deviceID: mac) { profile, locks in
        CompanionOwnerDeviceTurn(profile: profile, locks: locks, transport: mailbox)
    }
    let report = try await draining.run(profile: p, locks: CompanionDeviceDecisionLocks(), outcomes: outcomes, timeZone: utc, clock: { morning })
    #expect(report.decisionsCommitted == 1)
    #expect(!f.openIDs().contains("estate-example-2026-007"))
    #expect(await mailbox.deleted == [requestID(50)])
    #expect(await outcomes.published == [phone])
    // Nothing left: the next drain decides and publishes nothing.
    let quiet = try await draining.run(profile: p, locks: CompanionDeviceDecisionLocks(), outcomes: outcomes, timeZone: utc, clock: { morning })
    #expect(quiet.decisionsCommitted == 0)
    #expect(await outcomes.published == [phone])
}
