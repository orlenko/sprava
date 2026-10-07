import Foundation
import Testing
@testable import SpravaCore

extension JSONObject {
    /// A copy of a `source` object with another revision.
    func merging(revision: String) -> JSONValue {
        var o = self
        o.set("revision", .string(revision))
        return .object(o)
    }
}

@Suite(.serialized) struct CaptureTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let device = "0f0e0d0c-0b0a-4908-8706-050403020100"

    struct Setup {
        let commands: Commands
        let inbox: CaptureInbox
        let producer: CaptureProducer
        let folder: URL
    }

    func setup(adopt: Bool = true) throws -> Setup {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-capture-\(UUID().uuidString)")
        let support = base.appendingPathComponent("support")
        let root = base.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        if adopt {
            let r = try JSONParser.parse(commands.handle(JSONWriter.compact(.obj([("command", .str("adopt")), ("binder", .string(folder.path))])),
                                                         now: now, today: today)).value
            #expect(r["ok"] == .bool(true), "\(r)")
            // Leave only the capture's cards for the tests to look at.
            for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: now) }
        }
        let inbox = CaptureInbox(root: root, support: support)
        try inbox.registerProducer(folder: device, app: "sprava")
        return Setup(commands: commands, inbox: inbox, producer: CaptureProducer(root: root, deviceID: device, support: support), folder: folder)
    }

    /// Writes a note the way the app does: the event, then the notice to the runtime.
    @discardableResult
    func note(_ s: Setup, _ text: String, hint: String? = nil, notice: Bool = true) throws -> JSONObject {
        let (event, digest) = try s.producer.writeNote(text, binderHint: hint, startedAt: now, savedAt: now, locale: "en-CA")
        if notice { try s.inbox.recordNotice(event: event["id"]!.stringValue!, digest: digest) }
        return event
    }

    func rows(_ s: Setup) -> [ShelfRow] {
        [ShelfRow(folder: s.folder, source: .picked, archived: false, teka: Teka.read(s.folder))]
    }

    func open(_ s: Setup) -> [Proposal] { ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" } }

    func write(_ o: JSONObject, to url: URL) throws { try Data(JSONWriter.pretty(.object(o)).utf8).write(to: url) }

    /// A copy of `event` as another device folder would hold it.
    func copy(_ event: JSONObject, into s: Setup, device other: String, change: (inout JSONObject) -> Void = { _ in }) throws -> URL {
        let folder = s.producer.root.appendingPathComponent(other)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var c = event
        let id = UUIDv7.make(now: now)
        c.set("id", .string(id))
        c.set("device", .obj([("id", .string(other))]))
        c.set("hlc", .obj([("wall_ms", .int(1)), ("counter", .int(0)), ("node", .string(other.replacingOccurrences(of: "-", with: "")))]))
        change(&c)
        let url = folder.appendingPathComponent("\(id).json")
        try write(c, to: url)
        return url
    }

    @Test func aTypedNoteIsACompleteEventWithAnOffset() throws {
        let s = try setup(adopt: false)
        let event = try note(s, "Call the notary")
        let id = try #require(event["id"]?.stringValue)
        let file = s.producer.folder.appendingPathComponent("\(id).json")
        let (check, read) = CaptureEvent.check(file, deviceFolder: s.producer.folder)
        #expect(check == .complete(.capture))
        #expect(read?.text == "Call the notary")
        #expect(event["captured_at"]?.stringValue?.hasSuffix("Z") == false)
        #expect(CaptureProducer.offsetTime(now, timeZone: utc).hasSuffix("+00:00"))
        #expect(event["hlc"]?["node"] == .string(device.replacingOccurrences(of: "-", with: "")))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // No temp file is left behind, and the clock moves forward even when the wall clock does not.
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.producer.folder.path).count == 1)
        let second = try note(s, "Again")
        #expect(second["hlc"]?["wall_ms"] == event["hlc"]?["wall_ms"])
        #expect(second["hlc"]?["counter"] == .int(1))
    }

    @Test func aNoteWithoutAHintBecomesAnUnfiledCard() throws {
        let s = try setup()
        try note(s, "Call the notary\n\n  Ask about the inventory  \n")
        let r = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now.addingTimeInterval(5))
        #expect(r.ingested == 1 && r.unfiled == 1 && r.filed == 0)
        #expect(r.latencies == [5])
        let cards = s.inbox.unfiled()
        #expect(cards.count == 1)
        #expect(cards[0].raw["binder"] == .str("not sure"))
        #expect(cards[0].ops.map { $0["args"]?["item"]?["title"]?.stringValue } == ["Call the notary", "Ask about the inventory"])
        #expect(cards[0].ops[1]["spans"]?.arrayValue?.first?["start"] == .int(19))
        #expect(cards[0].ops[1]["spans"]?.arrayValue?.first?["end"] == .int(42))
        #expect(cards[0].actor["model"] == .str("none"))
        #expect(cards[0].raw["provenance"]?["unverified_source"] == nil)
        #expect(open(s).isEmpty)
        // A second sweep finds nothing new.
        #expect(s.inbox.sweep(binders: rows(s), commands: s.commands, now: now).ingested == 0)
        #expect(s.inbox.unfiled().count == 1)
    }

    @Test func aHintNamingAnAdoptedBinderFilesTheCardThereAndItCanBeApproved() throws {
        let s = try setup()
        try note(s, "Send the signed form", hint: Teka.read(s.folder).name)
        let r = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        #expect(r.filed == 1 && r.unfiled == 0)
        let card = try #require(open(s).first)
        let listed = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([("command", .str("proposals")),
                                                                                     ("binder", .string(s.folder.path))])), now: now, today: today)).value
        let shown = try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(card.id) })
        #expect(shown["verified"] == .bool(true))
        let approved = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([
            ("command", .str("approve")), ("binder", .string(s.folder.path)), ("proposal", .string(card.id)), ("digest", shown["digest"]!)])),
            now: now, today: today)).value
        #expect(approved["ok"] == .bool(true), "\(approved)")
        let added = Teka.read(s.folder).items.last
        #expect(added?.raw["title"] == .str("Send the signed form"))
        #expect(added?.raw["no_deadline"] == .bool(true))
        #expect(added?.raw["provenance"]?["proposed_by"]?["kind"] == .str("clerk"))
    }

    @Test func aHintWithoutTheAppsNoticeIsIgnoredAndTheCardIsUnverified() throws {
        let s = try setup()
        try note(s, "Wire the deposit", hint: Teka.read(s.folder).name, notice: false)
        let r = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        #expect(r.filed == 0 && r.unfiled == 1)
        #expect(s.inbox.unfiled().first?.raw["provenance"]?["unverified_source"] == .bool(true))
        #expect(open(s).isEmpty)
    }

    @Test func aHintIntoABinderAtDisclosureNoneStaysUnfiled() throws {
        let s = try setup()
        let ok = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([
            ("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("set_disclosure")),
            ("args", .obj([("disclosure", .str("none"))]))])), now: now, today: today)).value
        #expect(ok["ok"] == .bool(true), "\(ok)")
        try note(s, "Sign the deed", hint: Teka.read(s.folder).name)
        #expect(s.inbox.sweep(binders: rows(s), commands: s.commands, now: now).unfiled == 1)
    }

    @Test func privateCapturesAreRedactedAndUnknownSensitivityReadsAsPrivate() throws {
        let s = try setup()
        let event = try note(s, "Pay the deposit", notice: false)
        let id = try #require(event["id"]?.stringValue)
        var raw = event
        raw.set("sensitivity", .str("secret-ish"))
        try write(raw, to: s.producer.folder.appendingPathComponent("\(id).json"))
        _ = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        let card = try #require(s.inbox.unfiled().first)
        #expect(card.ops.first?["args"]?["item"]?["redact"] == .bool(true))
        #expect(card.raw["provenance"]?["private"] == .bool(true))
    }

    @Test func halfWrittenEventsWaitAndBadOnesAreQuarantined() throws {
        let s = try setup()
        let event = try note(s, "Book the appraiser")
        let id = try #require(event["id"]?.stringValue)
        let file = s.producer.folder.appendingPathComponent("\(id).json")
        let whole = try Data(contentsOf: file)
        try whole.prefix(40).write(to: file)
        var r = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        #expect(r.pending == 1 && r.ingested == 0)
        try whole.write(to: file)
        r = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        #expect(r.ingested == 1)

        // An id that differs from its file name, a device id that differs from its folder, a stray name, and an
        // event claiming another app in a registered folder.
        var wrong = event
        wrong.set("id", .string(UUIDv7.make(now: now)))
        try write(wrong, to: s.producer.folder.appendingPathComponent("\(UUIDv7.make(now: now)).json"))
        let stray = "11111111-2222-4333-8444-555555555555"
        let movedURL = try copy(event, into: s, device: stray) { $0.set("device", .obj([("id", .str("someone-else"))])) }
        try Data("{}".utf8).write(to: movedURL.deletingLastPathComponent().appendingPathComponent("notes.json"))
        var forged = event
        let forgedID = UUIDv7.make(now: now)
        forged.set("id", .string(forgedID))
        forged.set("source", .obj([("app", .str("holos")), ("kind", .str("dictation")), ("ref", .str("r")), ("revision", .str("1"))]))
        try write(forged, to: s.producer.folder.appendingPathComponent("\(forgedID).json"))
        r = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        #expect(r.quarantined == 4 && r.ingested == 0)
        let journal = try String(contentsOf: s.inbox.journalURL, encoding: .utf8)
        #expect(journal.contains("\"quarantined\""))
        #expect(!journal.contains("Book the appraiser"))   // the journal never carries text
        #expect(s.inbox.health().quarantined == 4)
        // A quarantined file is not looked at again until it changes.
        #expect(s.inbox.sweep(binders: rows(s), commands: s.commands, now: now).quarantined == 0)
    }

    @Test func linksAndOpenFoldersAreRefused() throws {
        let s = try setup()
        let event = try note(s, "Order the plaque")
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let linked = "22222222-3333-4444-8555-666666666666"
        try FileManager.default.createSymbolicLink(at: s.producer.root.appendingPathComponent(linked), withDestinationURL: elsewhere)
        // A linked event file inside a real folder is refused too.
        let real = s.producer.folder.appendingPathComponent("\(event["id"]!.stringValue!).json")
        let other = "33333333-4444-4555-8666-777777777777"
        let folder = s.producer.root.appendingPathComponent(other)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let linkID = UUIDv7.make(now: now)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("\(linkID).json"), withDestinationURL: real)
        let r = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        #expect(r.refusedFolders == 1)
        #expect(r.ingested == 1 && r.quarantined == 1)
        chmod(s.producer.root.path, 0o777)
        #expect(s.inbox.sweep(binders: rows(s), commands: s.commands, now: now).refusedFolders == 1)
    }

    @Test func theSameSourceRevisionFromTwoDevicesIsIngestedOnce() throws {
        let s = try setup()
        let event = try note(s, "Renew the permit")
        _ = try copy(event, into: s, device: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let r = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        #expect(r.ingested == 1 && r.duplicates == 1)
        #expect(s.inbox.unfiled().count == 1)
    }

    @Test func aCorrectionReplacesTheWaitingCardAndOnlyARegisteredProducerCanChangeAChain() throws {
        let s = try setup()
        let first = try note(s, "Call the roofer")
        _ = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        // The same thing edited after saving: a later event of the same chain (app and ref), new revision and text.
        let (second, digest) = try s.producer.writeNote("Call the roofer on Monday", startedAt: now, savedAt: now)
        var corrected = second
        corrected.set("source", first["source"]!.objectValue!.merging(revision: "sha256:edited"))
        corrected.set("supersedes", first["id"]!)
        let url = s.producer.folder.appendingPathComponent("\(second["id"]!.stringValue!).json")
        try FileManager.default.removeItem(at: url)
        try write(corrected, to: url)
        _ = digest
        // Another device folder, unregistered, claiming the same app and ref: it cannot change the chain.
        _ = try copy(first, into: s, device: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee") {
            $0.set("supersedes", first["id"]!)
            $0.set("retracted", .bool(true))
            $0.set("text", .str(""))
            $0.set("source", first["source"]!.objectValue!.merging(revision: "retracted"))
        }
        _ = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        let cards = s.inbox.unfiled()
        #expect(cards.count == 1)
        #expect(cards[0].title.hasPrefix("Corrected note"))
        #expect(cards[0].raw["provenance"]?["supersedes"] == first["id"])
        #expect(cards[0].ops.first?["args"]?["item"]?["title"] == .str("Call the roofer on Monday"))
    }

    @Test func anUnfiledCardCanBeFiledThroughCommandsButNotWhenTampered() throws {
        let s = try setup()
        try note(s, "Collect the keys")
        try note(s, "Return the keys")
        _ = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        let listed = try JSONParser.parse(s.commands.handle(#"{"command":"unfiled"}"#, now: now, today: today)).value
        let cards = try #require(listed["cards"]?.arrayValue)
        #expect(cards.count == 2)
        let first = try #require(cards[0]["id"])
        // The second card's file is rewritten by another program: it is no longer listed or fileable.
        let tamperedID = try #require(cards[1]["id"]?.stringValue)
        let tampered = s.inbox.unfiledDir.appendingPathComponent("\(tamperedID).json")
        try (String(contentsOf: tampered, encoding: .utf8).replacingOccurrences(of: "Return", with: "Burn")).write(to: tampered, atomically: true, encoding: .utf8)
        #expect(s.inbox.unfiled().count == 1)
        let refused = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([("command", .str("file_card")), ("card", .string(tamperedID)),
                                                                                      ("binder", .string(s.folder.path))])), now: now, today: today)).value
        #expect(refused["ok"] == .bool(false))

        let filed = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([("command", .str("file_card")), ("card", first),
                                                                                    ("binder", .string(s.folder.path))])), now: now, today: today)).value
        #expect(filed["ok"] == .bool(true), "\(filed)")
        let proposal = try #require(open(s).first)
        #expect(proposal.raw["binder"] == nil)
        let applied = try TekaStore(folder: s.folder).approve(proposal, now: now)
        #expect(applied.count == 1)
        let discarded = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([("command", .str("discard_card")), ("card", .string(tamperedID))])),
                                                               now: now, today: today)).value
        #expect(discarded["ok"] == .bool(true))
        #expect(s.inbox.unfiled().isEmpty)
    }

    @Test func linesCountUnicodeScalars() {
        let lines = CaptureInbox.lines(of: "🙂 one\r\ntwo  \n\n three")
        #expect(lines.map(\.text) == ["🙂 one", "two", "three"])
        #expect(lines.map(\.start) == [0, 7, 15])
        #expect(lines.map(\.end) == [5, 10, 20])
    }
}
