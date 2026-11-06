import BinderFormat
import BinderStore
import Capture
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// An approved draft card leaves a request with its message; the runtime places it in the account's Drafts folder, and
/// only then removes it (decisions.md D41, integrations.md §5.2). Invented binders, accounts and mail; no server.
@Suite(.serialized) struct DraftPlacingTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("claude"))])

    func setup(connected: Bool = true) throws -> (Commands, URL, BinderIMAPConnections) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-drafts-\(UUID().uuidString)")
        let c = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = c.handle(JSONWriter.compact(.obj([("command", .str("adopt")), ("binder", .string(folder.path))])), now: now, today: today)
        let connections = try BinderIMAPConnections(support: support, hash: { "fixture" })
        if connected {
            let account = try #require(IMAPAccount(host: "mail.example.invalid", port: 993, security: .tls, user: "me@example.invalid"))
            _ = try connections.configure(folder: folder, account: account, mailbox: "INBOX")
        }
        return (c, folder, connections)
    }

    func card(_ c: Commands, _ folder: URL) throws -> (Proposal, JSONValue) {
        let draft = DraftCard(to: ["supplier@example.com"], subject: "Invoice for October", body: "Hello,\n\nCould you send the invoice?\n")
        let card = try draft.proposal(actor: actor, catalog: Teka.read(folder).catalog, now: now)
        try ProposalStore.save(card, in: folder)
        try c.trustProposals([card.id], in: folder)
        try c.recordDraftCard(card.id, in: folder)
        let listed = try JSONParser.parse(c.handle(JSONWriter.compact(.obj([("command", .str("proposals")), ("binder", .string(folder.path))])), now: now, today: today)).value
        return (card, try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(card.id) }?["digest"]))
    }

    func approve(_ c: Commands, _ folder: URL, _ card: Proposal, _ digest: JSONValue) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj([("command", .str("approve")), ("binder", .string(folder.path)),
                                                               ("proposal", .string(card.id)), ("digest", digest)])), now: now, today: today)).value
    }

    @Test func approvingADraftLeavesItsMessageReadyAndALogEntryWithoutTheBody() throws {
        let (c, folder, _) = try setup()
        let (card, digest) = try card(c, folder)
        #expect(try approve(c, folder, card, digest)["ok"] == .bool(true))
        let requests = DraftRequests(support: c.support)
        #expect(requests.all().map(\.state) == [.ready])
        let message = String(decoding: try requests.message(id: card.id), as: UTF8.self)
        #expect(message.contains("From: me@example.invalid\r\n") && message.contains("Message-ID: \(DraftCard.messageID(card: card.id))\r\n"))
        let log = Teka.read(folder).catalog?["processing_log"]?.arrayValue ?? []
        #expect(log.contains { $0["action"] == .str("Email draft to supplier@example.com: Invoice for October") })
        #expect(!JSONWriter.compact(.array(log)).contains("Could you send"))
    }

    @Test func aBinderWithNoEmailConnectionApprovesNoDraft() throws {
        let (c, folder, _) = try setup(connected: false)
        let (card, digest) = try card(c, folder)
        let r = try approve(c, folder, card, digest)
        #expect(r["ok"] == .bool(false))
        #expect(r["error"]?.stringValue?.contains("no email connection") == true)
        #expect(DraftRequests(support: c.support).all().isEmpty)
        #expect(ProposalStore.list(in: folder).first { $0.0.id == card.id }?.0.state == "proposed")
    }

    /// Only a draft card Sprava wrote, in exactly its shape, is approved as one: another card holding a draft is not.
    @Test func aDraftSpravaDidNotWriteIsNeverApproved() throws {
        let (c, folder, _) = try setup()
        let draft = DraftCard(to: ["supplier@example.com"], subject: "Invoice", body: "Invented.")
        // Trusted as a card, but not recorded as a draft Sprava wrote.
        let unrecorded = try draft.proposal(actor: actor, catalog: Teka.read(folder).catalog, now: now)
        try ProposalStore.save(unrecorded, in: folder)
        try c.trustProposals([unrecorded.id], in: folder)
        // Ordinary ops with a draft riding along in its provenance.
        var raw = unrecorded.raw
        raw.set("id", .string(UUIDv7.make(now: now.addingTimeInterval(1))))
        raw.set("ops", .array(unrecorded.raw["ops"]!.arrayValue! + [.obj([("op", .str("add_log_entry")), ("args", .obj([("entry", .obj([("action", .str("Invented"))]))]))])]))
        let riding = Proposal(raw: raw)
        try ProposalStore.save(riding, in: folder)
        try c.trustProposals([riding.id], in: folder)
        try c.recordDraftCard(riding.id, in: folder)
        #expect(DraftCard(riding) == nil)
        let listed = try JSONParser.parse(c.handle(JSONWriter.compact(.obj([("command", .str("proposals")), ("binder", .string(folder.path))])), now: now, today: today)).value
        for card in [unrecorded, riding] {
            let digest = try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(card.id) }?["digest"])
            let r = try approve(c, folder, card, digest)
            #expect(r["ok"] == .bool(false))
            #expect(r["error"]?.stringValue?.contains("Sprava did not write") == true)
        }
        #expect(DraftRequests(support: c.support).all().isEmpty)
    }

    final class Placer: @unchecked Sendable {
        let lock = NSLock()
        var messages: [Data] = []
        var failure: (any Error)?
        func place(_ config: BinderIMAPConnections.Configuration, _ password: String, _ message: Data, _ dir: URL) throws -> IMAPDraftAppend.Placed {
            try lock.withLock {
                if let failure { throw failure }
                messages.append(message)
                return .init(folder: "Drafts", uid: 7, present: false)
            }
        }
    }

    func run(_ c: Commands, _ connections: BinderIMAPConnections, _ placer: Placer, password: String? = "invented", at: Date? = nil) -> DraftPlacing.Outcome {
        DraftPlacing.run(support: c.support, connections: connections, password: { _ in password }, available: { _ in true },
                         place: { try placer.place($0, $1, $2, $3) }, now: at ?? now)
    }

    @Test func theRuntimePlacesAnApprovedDraftOnceAndThenItIsGone() throws {
        let (c, folder, connections) = try setup()
        let (card, digest) = try card(c, folder)
        _ = try approve(c, folder, card, digest)
        let placer = Placer()
        // No password here: it waits, and the server is never tried.
        #expect(run(c, connections, placer, password: nil) == .waiting)
        #expect(placer.messages.isEmpty)
        #expect(run(c, connections, placer) == .placed)
        #expect(placer.messages.count == 1)
        #expect(String(decoding: placer.messages[0], as: UTF8.self).contains(DraftCard.messageID(card: card.id)))
        #expect(DraftRequests(support: c.support).all().isEmpty)
        #expect(run(c, connections, placer) == .none)
        // Each attempt's private folder is gone afterwards.
        let attempts = (try? FileManager.default.contentsOfDirectory(atPath: c.support.appendingPathComponent("capture/draft-attempts").path)) ?? []
        #expect(attempts.isEmpty)
    }

    @Test func aFailureThatWillNotPassWaitsForThePersonAndOneThatMayIsTriedAgain() throws {
        let (c, folder, connections) = try setup()
        let (card, digest) = try card(c, folder)
        _ = try approve(c, folder, card, digest)
        let requests = DraftRequests(support: c.support)
        let placer = Placer()
        placer.failure = IMAPIntakeImport.Refused.unavailable
        #expect(run(c, connections, placer) == .waiting)
        #expect(requests.all().map(\.state) == [.ready])
        for (failure, reason) in [(IMAPDraftAppend.Refused.noDraftsFolder as any Error, "no drafts folder"),
                                  (IMAPIntakeImport.Refused.authentication, "sign-in refused"), (IMAPIntakeImport.Refused.untrusted, "certificate changed")] {
            try requests.ready(id: card.id)
            placer.failure = failure
            #expect(run(c, connections, placer) == .failed)
            #expect(requests.all().first?.failure == reason)
        }
        // Failed stays failed until the person chooses Try again; nothing is placed meanwhile.
        placer.failure = nil
        #expect(run(c, connections, placer) == .none)
        #expect(placer.messages.isEmpty)
        // The binder's connection moved to another account since approval: the draft goes nowhere.
        try requests.ready(id: card.id)
        let other = try #require(IMAPAccount(host: "mail.example.invalid", port: 993, security: .tls, user: "someone-else@example.invalid"))
        _ = try connections.configure(folder: folder, account: other, mailbox: "INBOX")
        #expect(run(c, connections, placer) == .waiting || requests.all().first?.failure == "account changed")
        #expect(requests.all().first?.failure == "account changed" && placer.messages.isEmpty)
        // A binder whose email connection was removed fails at once.
        try requests.ready(id: card.id)
        try connections.disable(folder: folder)
        _ = run(c, connections, placer)
        #expect(placer.messages.isEmpty || requests.all().isEmpty)
    }

    /// An approval that did not finish: long after, its request is placed when the card is approved, and removed when not.
    @Test func aRequestLeftByAnUnfinishedApprovalIsSettled() throws {
        let (c, folder, connections) = try setup()
        let requests = DraftRequests(support: c.support)
        let (card, _) = try card(c, folder)
        try requests.begin(id: card.id, binder: folder, account: "me@example.invalid@mail.example.invalid:993", message: Data("Message-ID: <a@b>\r\n\r\nx".utf8), now: now)
        let placer = Placer()
        // Recent: an approval may be writing it now, so it is left alone.
        #expect(run(c, connections, placer, at: now.addingTimeInterval(60)) == .none)
        #expect(requests.all().map(\.state) == [.approving])
        // Long after, with the card never approved: removed, never placed.
        #expect(run(c, connections, placer, at: now.addingTimeInterval(3600)) == .none)
        #expect(requests.all().isEmpty && placer.messages.isEmpty)
        // With the card's ops written but the card not yet marked, as a stop between the two leaves it: placed.
        try requests.begin(id: card.id, binder: folder, account: "me@example.invalid@mail.example.invalid:993", message: Data("Message-ID: <a@b>\r\n\r\nx".utf8), now: now)
        _ = try TekaStore(folder: folder).approve(card, now: now)
        var unmarked = try #require(ProposalStore.list(in: folder).first { $0.0.id == card.id }?.0).raw
        unmarked.set("state", .str("proposed"))
        try ProposalStore.save(Proposal(raw: unmarked), in: folder)
        #expect(run(c, connections, placer, at: now.addingTimeInterval(3600)) == .placed)
        #expect(placer.messages.count == 1)
    }
}

/// The binder's page lists its approved drafts not placed yet, and the person may try a failed one again or discard it;
/// only a draft of that binder (integrations.md §5.2).
@Suite(.serialized) struct DraftCommandTests {
    @Test func thePageListsRetriesAndDiscardsOnlyItsOwnDrafts() async throws {
        let outer = DraftPlacingTests()
        let (c, folder, connections) = try outer.setup()
        let (other, otherFolder, _) = try outer.setup()
        _ = other
        let requests = DraftRequests(support: c.support)
        let mine = UUIDv7.make(now: outer.now), theirs = UUIDv7.make(now: outer.now.addingTimeInterval(1))
        try requests.begin(id: mine, binder: folder, account: "x", message: Data("x".utf8), now: outer.now)
        try requests.failed(id: mine, reason: "no drafts folder")
        try requests.begin(id: theirs, binder: otherFolder, account: "x", message: Data("x".utf8), now: outer.now)
        let runtime = BinderIMAPRuntime(support: c.support, connections: connections, passwords: BinderIMAPRuntimeTests.passwords(),
                                        fetch: { _, _, _ in throw IMAPIntakeImport.Refused.unavailable })
        func ask(_ command: String, _ fields: [(String, JSONValue)] = []) async throws -> JSONValue {
            try JSONParser.parse(await runtime.respond(BinderIMAPRuntimeTests.request(command, folder, fields))).value
        }
        let listed = try await ask("imap_drafts")
        #expect(listed["drafts"]?.arrayValue?.map { $0["id"] } == [.string(mine)])
        #expect(listed["drafts"]?.arrayValue?.first?["failure"] == .str("no drafts folder"))
        #expect(try await ask("imap_draft_retry", [("id", .string(mine))])["drafts"]?.arrayValue?.first?["state"] == .str("ready"))
        // Another binder's draft is never touched from this one.
        #expect(try await ask("imap_draft_discard", [("id", .string(theirs))])["ok"] == .bool(false))
        #expect(requests.all().contains { $0.id == theirs })
        #expect(try await ask("imap_draft_discard", [("id", .string(mine))])["drafts"]?.arrayValue?.isEmpty == true)
        #expect(requests.all().map(\.id) == [theirs])
    }
}

/// What the bug hunt found, each kept from coming back (decisions.md D41).
@Suite(.serialized) struct DraftPlacingHuntTests {
    let t = DraftPlacingTests()

    @Test func anAppliedDraftCardIsNeverQueuedAgain() throws {
        let (c, folder, connections) = try t.setup()
        let (card, digest) = try t.card(c, folder)
        _ = try t.approve(c, folder, card, digest)
        let placer = DraftPlacingTests.Placer()
        #expect(t.run(c, connections, placer) == .placed)
        // The same approval again, with the digest recorded after the first: refused, and nothing is queued.
        let again = try #require(try c.loadDigests()[c.key(folder, card.id)])
        #expect(JSONValue.string(again) != digest)
        let r = try t.approve(c, folder, card, .string(again))
        #expect(r["ok"] == .bool(false))
        #expect(r["error"]?.stringValue?.contains("applied") == true)
        #expect(DraftRequests(support: c.support).all().isEmpty)
        #expect(t.run(c, connections, placer, at: t.now.addingTimeInterval(3600)) == .none && placer.messages.count == 1)
    }

    @Test func aDraftWithNoKnownAnswerIsSpacedOutThenToldAndHoldsUpNoOther() throws {
        let (c, folder, connections) = try t.setup()
        let (first, d1) = try t.card(c, folder)
        _ = try t.approve(c, folder, first, d1)
        let requests = DraftRequests(support: c.support)
        let placer = DraftPlacingTests.Placer()
        placer.failure = IMAPIntakeImport.Refused.unavailable
        var at = t.now
        #expect(t.run(c, connections, placer, at: at) == .waiting)
        // Within the spacing it is not tried again.
        #expect(t.run(c, connections, placer, at: at.addingTimeInterval(60)) == .waiting)
        #expect(requests.all().first?.attempts == 1)
        at = at.addingTimeInterval(DraftPlacing.retryAfter + 1)
        #expect(t.run(c, connections, placer, at: at) == .waiting)
        at = at.addingTimeInterval(DraftPlacing.retryAfter + 1)
        #expect(t.run(c, connections, placer, at: at) == .failed)
        #expect(requests.all().first?.failure == "not placed: the server refused it or did not answer")
    }

    /// The card file is not proof: only the binder's op log says an approval went through.
    @Test func aCardFileSayingAppliedIsNoApproval() throws {
        let (c, folder, connections) = try t.setup()
        let (card, _) = try t.card(c, folder)
        let requests = DraftRequests(support: c.support)
        try requests.begin(id: card.id, binder: folder, account: "me@example.invalid@mail.example.invalid:993", message: Data("Message-ID: <a@b>\r\n\r\nx".utf8), now: t.now)
        var forged = card.raw
        forged.set("state", .str("applied"))
        try ProposalStore.save(Proposal(raw: forged), in: folder)
        let placer = DraftPlacingTests.Placer()
        #expect(t.run(c, connections, placer, at: t.now.addingTimeInterval(3600)) == .none)
        #expect(requests.all().isEmpty && placer.messages.isEmpty)
    }

    @Test func aBinderPutAwayKeepsItsDraftsFromGoingLater() async throws {
        let (c, folder, connections) = try t.setup()
        let (card, digest) = try t.card(c, folder)
        _ = try t.approve(c, folder, card, digest)
        let runtime = BinderIMAPRuntime(support: c.support, connections: connections, passwords: BinderIMAPRuntimeTests.passwords(),
                                        fetch: { _, _, _ in throw IMAPIntakeImport.Refused.unavailable })
        try await runtime.retire(folder)
        #expect(DraftRequests(support: c.support).all().first?.failure == "binder put away")
        #expect(t.run(c, connections, DraftPlacingTests.Placer()) == .none)
    }
}
