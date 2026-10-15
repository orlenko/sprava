import Foundation
import SpravaKit
import Testing
@testable import Services

private actor PhoneActionPause {
    private var entered = false, opened = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            release = continuation; entered = true; observer?.resume(); observer = nil
        }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func open() { opened = true; release?.resume(); release = nil }
}
private final class PhoneActionReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(String, String)] = []
    func receive(_ answer: String, _ command: String, _ ms: Int) {
        #expect(ms >= 0)
        lock.lock(); records.append((answer, command)); lock.unlock()
    }
    func snapshot() -> [(String, String)] { lock.lock(); defer { lock.unlock() }; return records }
}
private enum PhoneFixtureError: Error, CustomStringConvertible {
    case refused
    var description: String { "invented-setup-code-and-relay-body" }
}

@Test func anAwaitingPhoneActionLeavesBinderCommandsAndStatusFreeAndRefusesOverlap() async throws {
    let pause = PhoneActionPause()
    let watch = WatchBox(budgets: RequestQueues.budgets)
    let phone = try CompanionRequestQueue(handlers: ["companion_claim": { _ in
        await pause.pause()
        return JSONObject([(key: "state", value: .str("claimed"))])
    }], watch: watch)
    let queues = RequestQueues(watch: watch)
    let replies = PhoneActionReplies()
    let submitted = queues.submit(#"{"command":"companion_claim"}"#, handle: { _ in
        Issue.record("Phone work entered the binder writer"); return "{}"
    }, companion: phone, reply: replies.receive)
    let first = try #require(submitted)
    await pause.waitForEntry()
    #expect(watch.runningFor("app_companion_request") != nil)
    for command in ["ping", "companion_status"] {
        let answer = await withCheckedContinuation { continuation in
            queues.submit(JSONWriter.compact(.obj([("command", .string(command))])), handle: { _ in
                dispatchPrecondition(condition: .onQueue(queues.commands))
                return #"{"ok":true}"#
            }, companion: phone) { answer, name, _ in
                #expect(name == command); continuation.resume(returning: answer)
            }
        }
        #expect(answer == #"{"ok":true}"#)
    }
    #expect(phone.submit(#"{"command":"companion_claim"}"#, reply: replies.receive) == nil)
    let busy = try JSONParser.parse(try #require(replies.snapshot().first).0).value
    #expect(busy["ok"] == .bool(false))
    #expect(busy["error"]?.stringValue?.contains("Another Phone action") == true)
    #expect(watch.runningFor("app_companion_request") != nil)
    await pause.open(); await first.value
    #expect(watch.runningFor("app_companion_request") == nil)
    let success = try JSONParser.parse(try #require(replies.snapshot().last).0).value
    #expect(success["ok"] == .bool(true)); #expect(success["state"] == .str("claimed"))
    #expect(replies.snapshot().count == 2)
}

@Test func cancelledPhoneWorkReleasesAdmissionAndReturnsOneOpaqueAnswer() async throws {
    let pause = PhoneActionPause()
    let phone = try CompanionRequestQueue(handlers: ["companion_claim": { _ in
        await pause.pause(); try Task.checkCancellation(); return JSONObject()
    }], watch: nil)
    let replies = PhoneActionReplies()
    let task = try #require(phone.submit(#"{"command":"companion_claim"}"#, reply: replies.receive))
    await pause.waitForEntry(); task.cancel(); await pause.open(); await task.value
    let cancelled = try JSONParser.parse(try #require(replies.snapshot().first).0).value
    #expect(cancelled["ok"] == .bool(false))
    #expect(cancelled["error"]?.stringValue?.contains("cancelled") == true)
    let retry = try #require(phone.submit(#"{"command":"companion_claim"}"#, reply: replies.receive))
    await retry.value
    #expect(replies.snapshot().count == 2)
    #expect(try JSONParser.parse(replies.snapshot()[1].0).value["ok"] == .bool(true))
}

@Test func phoneHandlerErrorsNeverExposeTheirDescriptionAndTheNextActionCanRun() async throws {
    let phone = try CompanionRequestQueue(handlers: [
        "companion_claim": { _ in throw PhoneFixtureError.refused },
        "companion_devices": { _ in JSONObject([(key: "ok", value: .bool(false)),
                                                  (key: "error", value: .str("invented-secret")),
                                                  (key: "devices", value: .array([]))]) },
    ], watch: nil)
    let replies = PhoneActionReplies()
    await (try #require(phone.submit(#"{"command":"companion_claim"}"#, reply: replies.receive))).value
    await (try #require(phone.submit(#"{"command":"companion_devices"}"#, reply: replies.receive))).value
    let records = replies.snapshot()
    #expect(records.count == 2)
    #expect(!records[0].0.contains(PhoneFixtureError.refused.description))
    #expect(try JSONParser.parse(records[0].0).value["ok"] == .bool(false))
    let successful = try JSONParser.parse(records[1].0).value
    #expect(successful["ok"] == .bool(true)); #expect(successful["error"] == nil)
    #expect(successful["devices"] == .array([]))
}

@Test func phoneAdmissionRejectsAmbiguousOversizedOrUnregisteredRequestsWithoutCallingAHandler() throws {
    #expect(throws: CompanionRequestQueue.InvalidRegistration.self) {
        try CompanionRequestQueue(handlers: ["approve": { _ in JSONObject() }], watch: nil)
    }
    let phone = try CompanionRequestQueue(handlers: ["companion_configure": { _ in
        Issue.record("Invalid request reached a Phone handler"); return JSONObject()
    }], watch: nil)
    let replies = PhoneActionReplies()
    for request in ["not json", #"{"command":"companion_reset"}"#,
                    #"{"command":"companion_configure","command":"companion_configure"}"#,
                    JSONWriter.compact(.obj([("command", .str("companion_configure")),
                                            ("setup_code", .string(String(repeating: "x", count: 65_536)))]))] {
        #expect(phone.submit(request, reply: replies.receive) == nil)
    }
    #expect(replies.snapshot().count == 4)
    for reply in replies.snapshot() {
        #expect(reply.1 == "?")
        #expect(try JSONParser.parse(reply.0).value["ok"] == .bool(false))
    }
}
