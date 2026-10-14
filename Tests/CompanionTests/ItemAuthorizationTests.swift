import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class AuthorizationSecrets: CompanionCredentialStorage, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
}
private struct AuthorizationFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-authorization-" + UUID().uuidString)
    let secrets = AuthorizationSecrets()
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    let local = try! CompanionLocalBinderIdentity(bytes: Data(repeating: 76, count: 16))
    func prepare() throws -> (CompanionProfile, String) {
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 19, count: 32).base64EncodedString())
        let p = try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets)
        _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
        return (p, try p.showBinder(local).id)
    }
    func snapshot(_ p: CompanionProfile, _ binder: String, _ items: [JSONValue], indexed: Bool = true) throws -> Int64 {
        let view = try p.prepareView(binderID: binder, reading: CompanionViewReading(name: "Sample binder", today: "2026-10-15",
            generatedAt: "2026-10-15T12:00:00Z", openItems: items)).publication
        if indexed { #expect(try p.completeView(view)); let index = try p.prepareIndex(generatedAt: "2026-10-15T12:00:00Z"); #expect(try p.completeIndex(index)) }
        return view.version
    }
    func action(_ binder: String, _ kind: CompanionRequestedAction.Kind = .done, id: JSONValue = .string("item"), seen: Int64 = 1, date: String? = nil) -> CompanionRequestedAction {
        CompanionRequestedAction(kind: kind, madeAt: "2026-10-15T12:00:00Z", binderID: binder, itemID: id, seenVersion: seen, date: date, text: nil)
    }
    func reading(_ open: [JSONValue], closed: [JSONValue] = []) -> CompanionItemReading {
        CompanionItemReading(openItems: open, closedItems: closed, today: "2026-10-15")
    }
}
private func authorizationItem(id: JSONValue = .string("item"), status: String = "open", recurrence: String = "monthly") -> JSONValue {
    .object(JSONObject([("id", id), ("title", .string("Inspect")), ("status", .string(status)),
        ("due", .string("2026-10-20")), ("recurrence", .string(recurrence))]))
}

@Test func itemAuthorizationRejectsRemovedIdentitiesAndMissingItemsBeforeFutureVersionsAndDetectsAmbiguousIds() throws {
    let f = AuthorizationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let (p, binder) = try f.prepare()
    let item = authorizationItem(); _ = try f.snapshot(p, binder, [item])
    #expect(try p.authorizeItemAction(f.action(binder, seen: 2), reading: f.reading([])) == .rejected(.notInBinder))
    #expect(try p.authorizeItemAction(f.action(binder, seen: 2), reading: f.reading([item, item])) == .conflict)
    let closure = JSONValue.object(JSONObject([("id", .string("item")), ("action", .string("done"))]))
    #expect(try p.authorizeItemAction(f.action(binder), reading: f.reading([item], closed: [closure])) == .conflict)
    #expect(try p.authorizeItemAction(f.action(binder, seen: 2), reading: f.reading([item])) == .rejected(.futureVersion))
    try p.hideBinder(f.local); let replacement = try p.showBinder(f.local).id
    #expect(replacement != binder)
    #expect(try p.authorizeItemAction(f.action(binder), reading: f.reading([item])) == .rejected(.notShown))
}

@Test func hiddenWholeRecordChangesAndNewPendingSnapshotsPreventApplyingWhatThePhoneDidNotSee() throws {
    let f = AuthorizationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let (p, binder) = try f.prepare()
    let original = authorizationItem(), changed = authorizationItem(recurrence: "weekly")
    _ = try f.snapshot(p, binder, [original])
    #expect(try p.authorizeItemAction(f.action(binder), reading: f.reading([original])) == .mutation(.complete))
    #expect(try p.authorizeItemAction(f.action(binder), reading: f.reading([changed])) == .conflict)
    // Pending ciphertext already advances the whole-record snapshot even before it can enter an index.
    #expect(try f.snapshot(p, binder, [changed], indexed: false) == 2)
    #expect(try p.authorizeItemAction(f.action(binder), reading: f.reading([changed])) == .conflict)
    #expect(try p.authorizeItemAction(f.action(binder, seen: 2), reading: f.reading([changed])) == .rejected(.futureVersion))
    _ = try f.snapshot(p, binder, [changed])
    #expect(try p.authorizeItemAction(f.action(binder, seen: 3), reading: f.reading([changed])) == .mutation(.complete))
    _ = try f.snapshot(p, binder, [], indexed: false)
    #expect(try p.authorizeItemAction(f.action(binder, seen: 3), reading: f.reading([changed])) == .conflict)
}

@Test func itemAuthorizationUsesAllowedStatusesMacDatesAndClosedNoOpSemanticsWithoutWritingAnEffect() throws {
    let f = AuthorizationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let (p, binder) = try f.prepare()
    for status in ["open", "waiting", "blocked", "unknown"] {
        let item = authorizationItem(status: status), version = try f.snapshot(p, binder, [item]), reading = f.reading([item])
        #expect(try p.authorizeItemAction(f.action(binder, seen: version), reading: reading) == .mutation(.complete))
        #expect(try p.authorizeItemAction(f.action(binder, .drop, seen: version), reading: reading) == .mutation(.drop))
        let waiting = status == "waiting" || status == "blocked"
        #expect(try p.authorizeItemAction(f.action(binder, .arrived, seen: version), reading: reading) == (waiting ? .mutation(.arrived) : .conflict))
        #expect(try p.authorizeItemAction(f.action(binder, .followUp, seen: version, date: "2026-10-15"), reading: reading) == (waiting ? .mutation(.followUp(date: "2026-10-15")) : .conflict))
        #expect(try p.authorizeItemAction(f.action(binder, .postpone, seen: version, date: "2026-10-15"), reading: reading) == (waiting ? .conflict : .mutation(.postpone(date: "2026-10-15"))))
        for kind in [CompanionRequestedAction.Kind.followUp, .postpone] {
            #expect(try p.authorizeItemAction(f.action(binder, kind, seen: version, date: "2026-10-14"), reading: reading) == .conflict)
        }
    }
    let openDone = authorizationItem(status: "done")
    #expect(try p.authorizeItemAction(f.action(binder), reading: f.reading([openDone])) == .alreadyApplied)
    #expect(try p.authorizeItemAction(f.action(binder, .drop), reading: f.reading([openDone])) == .conflict)
    for (how, kind) in [("done", CompanionRequestedAction.Kind.done), ("dropped", .drop)] {
        let closed = JSONValue.object(JSONObject([("id", .string("item")), ("action", .string(how))]))
        #expect(try p.authorizeItemAction(f.action(binder, kind), reading: f.reading([], closed: [closed])) == .alreadyApplied)
        #expect(try p.authorizeItemAction(f.action(binder, .arrived), reading: f.reading([], closed: [closed])) == .conflict)
    }
    #expect(try p.store.read { try $0.rows("SELECT COUNT(*) FROM request_decisions") } == [[.integer(0)]])
}

@Test func itemAuthorizationKeepsNumericStringAndUnicodeScalarIdentitiesDistinct() throws {
    let f = AuthorizationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let (p, binder) = try f.prepare()
    let ids: [JSONValue] = [.number(JSONNumber(text: "1")), .string("1"), .string("é"), .string("e\u{301}")]
    let items = ids.map { authorizationItem(id: $0) }; _ = try f.snapshot(p, binder, items)
    for (id, item) in zip(ids, items) {
        #expect(try p.authorizeItemAction(f.action(binder, id: id), reading: f.reading([item])) == .mutation(.complete))
    }
    #expect(try p.authorizeItemAction(f.action(binder, id: ids[0]), reading: f.reading([items[1]])) == .rejected(.notInBinder))
    #expect(try p.authorizeItemAction(f.action(binder, id: ids[2]), reading: f.reading([items[3]])) == .rejected(.notInBinder))
}
