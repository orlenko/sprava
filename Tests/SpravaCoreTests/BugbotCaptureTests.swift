import CryptoKit
import Darwin
import Foundation
import Testing
@testable import SpravaCore

// Regression tests for the review of the capture and clerk modules (increment 1). Invented data only.

/// The binder's agenda slice items, as the hub would publish them.
func bSlice(_ folder: URL) throws -> [JSONValue] {
    let catalog = try #require(Teka.read(folder).catalog)
    let (slice, _) = try HubLane.project(catalog: catalog, folderName: folder.lastPathComponent, closedOnce: [],
                                         key: SymmetricKey(size: .bits256), now: pNow)
    return slice["items"]?.arrayValue ?? []
}

/// A filing binder for the test binder, read from its catalog.
func bFiling(_ s: PSetup, description: String = "Estate of an invented relative") -> FilingBinder {
    let teka = Teka.read(s.folder)
    return FilingBinder(name: teka.name, description: description, folder: s.folder,
                        words: FilingBinder.index(catalog: teka.catalog, description: description),
                        openItems: FilingBinder.candidates(catalog: teka.catalog))
}

/// Adds a public open item by hand, as the person would.
func bAddItem(_ s: PSetup, id: String, title: String, extra: [(String, JSONValue)] = [("no_deadline", .bool(true))]) throws {
    let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("t"))])
    _ = try TekaStore(folder: s.folder).apply([.init(op: "add_item", args: JSONObject([(key: "item", value: .obj([
        ("id", .string(id)), ("title", .string(title)), ("status", .str("open")), ("priority", .str("normal"))] + extra))]), actor: actor)], now: pNow)
}

/// Sweeps, files the one unfiled card into the binder and approves it.
func bFileAndApprove(_ s: PSetup) throws {
    _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
    try s.inbox.file(try #require(s.inbox.unfiled().first).id, into: s.folder, commands: s.commands)
    _ = try TekaStore(folder: s.folder).approve(try #require(pOpen(s).first), now: pNow)
}

@Suite(.serialized) struct BugbotCaptureTests {

    // MARK: - Privacy

    // p8-QS: a private correction's change card redacts what it writes.
    @Test func p8QS_aPrivateCorrectionCardIsRedacted() throws {
        let s = try pSetup()
        let adapter = "11111111-2222-4333-8444-5555555555b1"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "Q1", revision: "rev1", text: "Call the roofer\nOrder the blinds")
        try bFileAndApprove(s)
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "Q1", revision: "rev2",
                       text: "Call the roofer about the invented leak\nOrder the blinds\nBook the chimney sweep") {
            $0.set("sensitivity", .str("private"))
        }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let card = try #require(pOpen(s).first { $0.title.contains("corrected") })
        #expect(card.raw["provenance"]?["private"] == .bool(true))
        let updates = card.ops.filter { $0["op"] == .str("update_item") }
        let adds = card.ops.filter { $0["op"] == .str("add_item") }
        #expect(updates.count == 1 && adds.count == 1)
        for u in updates {
            #expect(u["args"]?["set"]?["redact"] == .bool(true))
            #expect(u["args"]?["set"]?["kind"] == .str("other"))
        }
        #expect(adds.first?["args"]?["item"]?["redact"] == .bool(true))
        #expect(adds.first?["args"]?["item"]?["kind"] == .str("other"))
        // Approving the correction card alone publishes none of the private words.
        _ = try TekaStore(folder: s.folder).approve(card, now: pNow)
        let titles = try bSlice(s.folder).compactMap { $0["title"]?.stringValue }
        #expect(!titles.contains { $0.contains("leak") || $0.contains("chimney") })
    }

    // qcRsW: a private capture that updates a public item redacts it.
    @Test func qcRsW_aPrivateUpdateRedactsTheItem() async throws {
        let s = try pSetup()
        try bAddItem(s, id: "estate-example-2026-020", title: "Collect the garden photos")
        let text = "Collect the garden photos for the family by Friday."
        let ev = pEventObj(text) { $0.set("sensitivity", .str("private")) }
        let model = RecordingModel([.obj([("items", .array([item("Collect the garden photos", "Collect the garden photos", "other", when: "by Friday")]))])])
        model.dup = ("estate-example-2026-020", "update")
        let interp = await Clerk(model: model).read(ev, filing: [bFiling(s)], hint: "estate-example", now: pNow)
        let cards = Clerk.proposals(interp, event: ev, today: CalendarDate(year: 2026, month: 10, day: 6)!, client: "t", now: pNow)
        let op = try #require(cards.first?.1.ops.first)
        #expect(op["op"] == .str("update_item"))
        #expect(op["args"]?["set"]?["due"] == .str("2026-10-09"))
        #expect(op["args"]?["set"]?["redact"] == .bool(true))
        #expect(op["args"]?["set"]?["kind"] == .str("other"))
        try ProposalStore.save(cards[0].1, in: s.folder)
        _ = try TekaStore(folder: s.folder).approve(cards[0].1, now: pNow)
        let titles = try bSlice(s.folder).compactMap { $0["title"]?.stringValue }
        #expect(!titles.contains("Collect the garden photos"))
        #expect(titles.filter { $0 == "[redacted]" }.count == 2)   // the fixture's own redacted item, and this one
    }

    // MARK: - State durability

    /// A typed note the way the app sends it: the event, then its notice.
    @discardableResult
    func note(_ s: PSetup, _ text: String, hint: String? = nil) throws -> String {
        let n = try s.producer.prepareNote(text, binderHint: hint, startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: n.id, digest: n.digest)
        try s.producer.publish(n)
        return n.id
    }

    func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    // qIe1D: a cursor that cannot be read stops the sweep instead of being rebuilt over.
    @Test func qIe1D_anUnreadableCursorIsNeverRebuilt() throws {
        let s = try pSetup()
        try note(s, "Call the invented notary")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(s.inbox.unfiled().count == 1)
        try Data("{garbage".utf8).write(to: s.inbox.stateURL)
        let r = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(r.unreadable == "state.json")
        #expect(r.ingested == 0 && r.unfiled == 0)
        #expect(s.inbox.unfiled().count == 1)
        #expect(bytes(s.inbox.stateURL) == Data("{garbage".utf8))
        #expect(s.inbox.nextForClerk() == nil)
        #expect(bytes(s.inbox.stateURL) == Data("{garbage".utf8))
    }

    // qBssF: a card made before its id reached the cursor is found again, not made twice.
    @Test func qBssF_aCardMadeBeforeACrashIsReused() throws {
        let s = try pSetup()
        let id = try note(s, "Book the invented chimney sweep")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let first = try #require(s.inbox.unfiled().first)
        var st = try s.inbox.readState()
        st.ingested[id] = "ingested"
        st.cards[id] = nil
        st.clerk = [:]
        st.examined = [:]
        try s.inbox.save(st)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(s.inbox.unfiled().count == 1)
        #expect(try s.inbox.readState().cards[id] == first.id)
        #expect(try s.inbox.readState().ingested[id] == "unfiled")
    }

    // qI0_V: a raise to private that cannot be written is tried again by the next sweep.
    @Test func qI0V_aFailedPrivacyRaiseIsRetried() throws {
        let s = try pSetup()
        let adapter = "11111111-2222-4333-8444-5555555555b2"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        let first = try pEvent(s, device: adapter, app: "adapter", ref: "P2", revision: "rev1", text: "Meet the invented notary about the will")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        try s.inbox.file(try #require(s.inbox.unfiled().first).id, into: s.folder, commands: s.commands)
        let proposals = s.folder.appendingPathComponent(".sprava/proposals")
        chmod(proposals.path, 0o500)
        defer { chmod(proposals.path, 0o700) }
        let dup = try pEvent(s, device: adapter, app: "adapter", ref: "P2", revision: "rev1", text: "Meet the invented notary about the will") {
            $0.set("sensitivity", .str("private")); $0.set("supersedes", .string(first))
        }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(try s.inbox.readState().raises?[dup]?.contains(first) == true)   // kept for the next sweep
        #expect(pOpen(s).first?.ops.first?["args"]?["item"]?["redact"] == nil)
        chmod(proposals.path, 0o700)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let card = try #require(pOpen(s).first)
        #expect(card.ops.first?["args"]?["item"]?["redact"] == .bool(true))
        #expect(card.raw["provenance"]?["private"] == .bool(true))
        #expect(try s.inbox.readState().raises?[dup] == nil)
    }

    // qHLuP: an unreadable producer registry is never saved over.
    @Test func qHLuP_anUnreadableProducerRegistryIsKept() throws {
        let s = try pSetup()
        try Data("not json".utf8).write(to: s.inbox.producersURL)
        #expect(throws: (any Error).self) { try s.inbox.registerProducer(folder: "11111111-2222-4333-8444-5555555555b3", app: "adapter") }
        #expect(bytes(s.inbox.producersURL) == Data("not json".utf8))
        #expect(s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow).unreadable == "producers.json")
    }

    // qcRsA: an unreadable filing list is never saved over.
    @Test func qcRsA_anUnreadableFilingListIsKept() throws {
        let s = try pSetup()
        let list = FilingList(support: s.support)
        try AtomicFile.makePrivateFolder(s.support)
        try Data("[garbage".utf8).write(to: list.url)
        #expect(throws: (any Error).self) { try list.set(s.folder, .init(description: "Invented estate", filing: true)) }
        #expect(bytes(list.url) == Data("[garbage".utf8))
    }

    // qcRsH: unreadable unfiled digests are never saved over, and the cards come back once they read again.
    @Test func qcRsH_unreadableUnfiledDigestsAreKept() throws {
        let s = try pSetup()
        try note(s, "Call the invented plumber")
        try note(s, "Renew the invented library card")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(s.inbox.unfiled().count == 2)
        let good = try #require(bytes(s.inbox.unfiledDigestsURL))
        try Data("{".utf8).write(to: s.inbox.unfiledDigestsURL)
        try note(s, "Water the invented plants")
        let r = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(r.unreadable == "unfiled-digests.json")
        #expect(throws: (any Error).self) { try s.inbox.writeUnfiled(JSONObject([(key: "id", value: .str("x"))])) }
        #expect(bytes(s.inbox.unfiledDigestsURL) == Data("{".utf8))
        try good.write(to: s.inbox.unfiledDigestsURL)
        #expect(s.inbox.unfiled().count == 2)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(s.inbox.unfiled().count == 3)
    }

    // qHLuT: a notice that cannot be written is an error the app sees.
    @Test func qHLuT_aNoticeWriteFailureThrows() throws {
        let s = try pSetup()
        try FileManager.default.createDirectory(at: s.inbox.noticesURL, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try s.inbox.recordNotice(event: "01a10000-0000-7000-8000-0000000000ab", digest: "sha256:00")
        }
    }

    // qHLuX: the clerk's attempt is on disk before any model call, or there is no call.
    @Test func qHLuX_noClerkWorkWithoutARecordedAttempt() throws {
        let s = try pSetup()
        try note(s, "Pay the invented gardener")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        chmod(s.inbox.dir.path, 0o500)
        defer { chmod(s.inbox.dir.path, 0o700) }
        #expect(s.inbox.nextForClerk() == nil)
        chmod(s.inbox.dir.path, 0o700)
        #expect(s.inbox.nextForClerk() != nil)
        #expect(try s.inbox.readState().attempts?.values.first == 1)
    }

    // qHLuc: the code-built card stays until the interpretation is on disk.
    @Test func qHLuc_tier0StaysWhenTheInterpretationCannotBeWritten() async throws {
        let s = try pSetup()
        try note(s, "Call the invented notary about the deed", hint: "estate-example")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let work = try #require(s.inbox.nextForClerk())
        try Data().write(to: s.inbox.dir.appendingPathComponent("interpretations"))
        let model = RecordingModel([.obj([("items", .array([item("Call the invented notary", "Call the notary", "call")]))])])
        let interp = await Clerk(model: model).read(work.event, filing: [], hint: work.hint, now: pNow)
        let out = s.inbox.commitClerk(work, interp, filing: [], rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        #expect(!out.replaced)
        #expect(pOpen(s).map(\.id) == [work.tier0])
        #expect(try s.inbox.readState().clerk?[work.event.id] == "retry")
    }

    // qJwVo: a clerk commit that fails part way takes its cards back and is not retried into duplicates.
    @Test func qJwVo_aPartialClerkCommitIsTakenBack() async throws {
        let s = try pSetup()
        try note(s, "Call the invented notary. Order the invented blinds.", hint: "estate-example")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let work = try #require(s.inbox.nextForClerk())
        let model = RecordingModel([.obj([("items", .array([item("Call the invented notary", "Call the notary", "call"),
                                                            item("Order the invented blinds", "Order the blinds", "other")]))])])
        var interp = await Clerk(model: model).read(work.event, filing: [], hint: work.hint, now: pNow)
        #expect(interp.items.count == 2)
        interp.items[1].binder = nil   // "not sure"
        try AtomicFile.makePrivateFolder(s.inbox.unfiledDir)
        chmod(s.inbox.unfiledDir.path, 0o500)
        defer { chmod(s.inbox.unfiledDir.path, 0o700) }
        let out = s.inbox.commitClerk(work, interp, filing: [], rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        #expect(!out.replaced && out.filed == 0)
        #expect(pOpen(s).map(\.id) == [work.tier0])
        _ = s.inbox.commitClerk(work, interp, filing: [], rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        #expect(pOpen(s).map(\.id) == [work.tier0])
        #expect(s.inbox.nextForClerk() == nil)
    }

    // qJwVv: a filed card leaves the Inbox even when its file cannot be removed.
    @Test func qJwVv_aFiledCardLeavesTheInbox() throws {
        let s = try pSetup()
        try note(s, "Send the invented form")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let card = try #require(s.inbox.unfiled().first)
        chmod(s.inbox.unfiledDir.path, 0o500)
        defer { chmod(s.inbox.unfiledDir.path, 0o700) }
        try s.inbox.file(card.id, into: s.folder, commands: s.commands)
        #expect(s.inbox.unfiled().isEmpty)
        #expect(pOpen(s).map(\.id) == [card.id])
        #expect(throws: (any Error).self) { try s.inbox.file(card.id, into: s.folder, commands: s.commands) }
    }

    // qIlEc: an intake cursor that cannot be written is reported.
    @Test func qIlEc_anUnwritableIntakeCursorIsReported() throws {
        let s = try pSetup()
        let watcher = IntakeWatcher(support: s.support)
        try FileManager.default.createDirectory(at: watcher.stateURL, withIntermediateDirectories: true)
        #expect(watcher.scan(binders: pRows(s), commands: s.commands, now: pNow).cursorUnsaved)
        try FileManager.default.removeItem(at: watcher.stateURL)
        #expect(!watcher.scan(binders: pRows(s), commands: s.commands, now: pNow).cursorUnsaved)
    }
}
