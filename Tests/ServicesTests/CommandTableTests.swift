import BinderFormat
import BinderStore
import Darwin
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// The command table end to end: adopt, list and approve; stale or foreign cards; direct actions; another
/// device's binder; edits on a card before approving. Invented data only.
@Suite(.serialized) struct CommandTableTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func setup() throws -> (Commands, URL) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-cmd-\(UUID().uuidString)")
        return (Commands(support: support, deviceID: "dev"), try makeTeka(fixture: "lifeproj-v2-live"))
    }

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    @Test func templateLibraryRequestsNeedNoBinderThroughThePublicCommandEntry() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-library-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let commands = Commands(support: support, deviceID: "invented-device")
        let listed = try call(commands, [("command", .str("binder_templates"))])
        #expect(listed["ok"] == .bool(true))
        #expect(listed["templates"]?.arrayValue?.isEmpty == false)
        let opened = try call(commands, [("command", .str("binder_template_folder"))])
        #expect(opened["ok"] == .bool(true))
        #expect(opened["folder"] == .str(TemplateLibrary(support: support).folder.path))
    }

    @Test func adoptListApproveThroughCommands() throws {
        let (c, folder) = try setup()
        let adopted = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
        #expect(adopted["ok"] == .bool(true))
        let listed = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])
        let cards = try #require(listed["proposals"]?.arrayValue)
        #expect(cards.count == 2 && cards.allSatisfy { $0["verified"] == .bool(true) })
        for card in cards {
            let r = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)),
                                 ("proposal", card["id"]!), ("digest", card["digest"]!)])
            #expect(r["ok"] == .bool(true), "\(r)")
        }
        #expect(Teka.read(folder).state == .ready)
    }

    @Test func adoptionRefusesAnOversizedDashboardBeforeWritingAnything() throws {
        let (c, folder) = try setup()
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        let dashboard = folder.appendingPathComponent("DASHBOARD.md")
        try Data().write(to: dashboard)
        let handle = try FileHandle(forWritingTo: dashboard)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        let reply = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
        #expect(reply["ok"] == .bool(false) && reply["error"]?.stringValue?.contains("16 MiB") == true)
        #expect(Owner.device(of: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava/ops.ndjson").path))
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == catalog)
    }

    @Test(arguments: [false, true]) func adoptionRefusesExcessiveCatalogWorkBeforeWriting(padded: Bool) throws {
        let (c, folder) = try setup()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: file)).value.objectValue)
        let item = try #require(catalog["open_items"]?.arrayValue?.first?.objectValue)
        catalog.set("open_items", .array((0..<(padded ? 20 : 101)).map { n in
            var copy = item; copy.set("id", .str("invented-\(n)")); return .object(copy)
        }))
        if padded { catalog.set("invented_padding", .str(String(repeating: "x", count: 300_000))) }
        let before = Data(JSONWriter.compact(.object(catalog)).utf8)
        try before.write(to: file)
        let reply = try call(c, [("command", .str("adopt")), ("binder", .str(folder.path))])
        #expect(reply["ok"] == .bool(false) && reply["error"]?.stringValue?.contains("too large") == true)
        #expect(Owner.device(of: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava/ops.ndjson").path))
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func aNonBooleanSkipNeverApprovesTheOriginalOperation() throws {
        let (c, folder) = try setup()
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
        let card = try #require(ProposalStore.list(in: folder).first)
        let catalog = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        let reply = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)),
                                ("proposal", .str(card.0.id)), ("digest", .str(card.1)),
                                ("edits", .array([.obj([("index", .int(0)), ("skip", .str("true"))])]))])
        #expect(reply["ok"] == .bool(false) && reply["error"]?.stringValue?.contains("skip") == true)
        #expect(try ProposalStore.load(card.0.id, in: folder, expectedDigest: card.1).state == "proposed")
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == catalog)
    }

    @Test func anUnverifiedBulkCardIsPreservedInsteadOfRenderedWithoutBounds() throws {
        let (c, folder) = try setup()
        _ = try call(c, [("command", .str("adopt")), ("binder", .str(folder.path))])
        let op = JSONObject([(key: "op", value: .str("complete")), (key: "args", value: .obj([("id", .str("item-0003"))]))])
        let card = Proposal.make(title: "Invented bulk closure", actor: .init([(key: "kind", value: .str("brain"))]),
                                 ops: Array(repeating: op, count: 501), now: now)
        let digest = try ProposalStore.save(card, in: folder)
        try c.recordDigests([card.id], in: folder)
        let reply = try call(c, [("command", .str("proposals")), ("binder", .str(folder.path))])
        #expect(reply["ok"] == .bool(false) && reply["error"]?.stringValue?.contains("too large") == true)
        let approval = try call(c, [("command", .str("approve")), ("binder", .str(folder.path)),
                                   ("proposal", .str(card.id)), ("digest", .str(digest))])
        #expect(approval["ok"] == .bool(false) && approval["error"]?.stringValue?.contains("too large") == true)
        #expect(try ProposalStore.load(card.id, in: folder, expectedDigest: digest).state == "proposed")
    }

    @Test func anUnverifiedStampCannotRunFingerprintScansBeforeTheWorkLimit() throws {
        let (c, folder) = try setup()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try call(c, [("command", .str("adopt")), ("binder", .str(folder.path))])
        var raw = Proposal.make(title: "Invented stamp", actor: .init([(key: "kind", value: .str("brain"))]),
                                ops: [], now: now).raw
        raw.set("provenance", .obj([("adoption", .str("stamp"))]))
        raw.set("expect", .object(JSONObject((0..<501).map { (key: "absent-\($0)", value: .str("invented")) })))
        let card = Proposal(raw: raw), digest = try ProposalStore.save(Proposal(raw: raw), in: folder)
        let catalog = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        let reply = try call(c, [("command", .str("proposals")), ("binder", .str(folder.path))])
        #expect(reply["ok"] == .bool(false) && reply["error"]?.stringValue?.contains("too large") == true)
        #expect(try ProposalStore.load(card.id, in: folder, expectedDigest: digest).state == "proposed")
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == catalog)
    }

    @Test func anOverfullCollectionIsRefusedBeforeOfferingOrReviewingCards() throws {
        let (c, folder) = try setup()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try call(c, [("command", .str("adopt")), ("binder", .str(folder.path))])
        let card = try #require(ProposalStore.list(in: folder).first)
        let catalog = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        for n in 0..<101 {
            try Data().write(to: folder.appendingPathComponent(".sprava/proposals/invented-\(n).txt"))
        }
        for fields in [[("command", JSONValue.str("proposals")), ("binder", .str(folder.path))],
                       [("command", .str("approve")), ("binder", .str(folder.path)),
                        ("proposal", .str(card.0.id)), ("digest", .str(card.1))]] {
            let reply = try call(c, fields)
            #expect(reply["ok"] == .bool(false) && reply["error"]?.stringValue?.contains("too large") == true)
        }
        #expect(try ProposalStore.load(card.0.id, in: folder, expectedDigest: card.1).state == "proposed")
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == catalog)
    }

    @Test func aStaleOrForeignCardCannotBeApproved() throws {
        let (c, folder) = try setup()
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
        let card = try #require(try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue?.first)
        let stale = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)),
                                 ("proposal", card["id"]!), ("digest", .str("sha256:00"))])
        #expect(stale["ok"] == .bool(false))
        // A proposal file another program dropped in is listed as not verified and refused.
        let foreign = Proposal.make(title: "Close everything", actor: JSONObject([(key: "kind", value: .str("clerk"))]), ops: [], now: now)
        let digest = try ProposalStore.save(foreign, in: folder)
        let listed = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])
        #expect(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(foreign.id) }?["verified"] == .bool(false))
        let r = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)),
                             ("proposal", .string(foreign.id)), ("digest", .string(digest))])
        #expect(r["ok"] == .bool(false))
    }

    @Test func directActionsAreLimitedAndAttributedToTheUser() throws {
        let (c, folder) = try setup()
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
        let done = try call(c, [("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("complete")),
                                ("args", .obj([("id", .str("item-0003")), ("closed_at", .str("2026-10-07T09:00:00Z")), ("source", .str("user"))]))])
        #expect(done["ok"] == .bool(true))
        let ops = try TekaStore(folder: folder).readOpLog().ops
        #expect(ops.last?["actor"]?["kind"] == .str("user"))
        let refused = try call(c, [("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("external_edit")),
                                   ("args", .obj([("patch", .array([]))]))])
        #expect(refused["ok"] == .bool(false))
        let relative = try call(c, [("command", .str("proposals")), ("binder", .str("relative/path"))])
        #expect(relative["ok"] == .bool(false))
    }
}

@Suite struct OwnerTests {
    @Test func anotherDevicesBinderIsReadOnly() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-own-\(UUID().uuidString)")
        let mine = Commands(support: support, deviceID: "this-mac")
        let other = Commands(support: support, deviceID: "other-mac")
        _ = mine.handle(JSONWriter.compact(.obj([("command", .str("adopt")), ("binder", .string(folder.path))])))
        #expect(Owner.device(of: folder) == "this-mac")
        let r = try JSONParser.parse(other.handle(JSONWriter.compact(.obj([
            ("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("drop")),
            ("args", .obj([("id", .str("item-0006")), ("closed_at", .str("2026-10-07T09:00:00Z")), ("source", .str("user"))]))])))).value
        #expect(r["ok"] == .bool(false))
    }
}

/// What a binder in a damaged or unfinished state lets the commands read: nothing while an expunge is unfinished, no
/// op log or owner record that is a link or a FIFO, and no privacy card while its writes are blocked. Invented data only.
@Suite(.serialized) struct BinderStateGuardTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func adopted() throws -> (Commands, URL) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-guard-\(UUID().uuidString)")
        let c = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        #expect(try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])["ok"] == .bool(true))
        return (c, folder)
    }

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    func list(_ c: Commands, _ folder: URL) throws -> JSONValue {
        try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])
    }

    /// An outside file holding one op line with an invented title, as a link at the op log would point to.
    func outsideLog() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-outside-\(UUID().uuidString).ndjson")
        let line = #"{"id":"0199ffff-0000-7000-8000-0000000000aa","at":"2026-10-07T00:00:00Z","actor":{"kind":"user"},"op":"add_item","args":{"item":{"id":"x-1","title":"Invented outside title"}}}"#
        try Data((line + "\n").utf8).write(to: url)
        return url
    }

    @Test func nothingIsReadWhileAnExpungeIsUnfinished() throws {
        let (c, folder) = try adopted()
        let card = Proposal.make(title: "Invented title being forgotten", actor: JSONObject([(key: "kind", value: .str("clerk"))]), ops: [], now: now)
        try ProposalStore.save(card, in: folder)
        #expect(try list(c, folder)["proposals"]?.arrayValue?.isEmpty == false)
        try Data().write(to: folder.appendingPathComponent(".sprava/expunge-pending"))
        for command in ["proposals", "history", "binder_settings"] {
            let r = try call(c, [("command", .string(command)), ("binder", .string(folder.path))])
            #expect(r["ok"] == .bool(false) && r["error"]?.stringValue?.contains("expunge") == true, "\(command): \(r)")
            #expect(!JSONWriter.compact(r).contains("Invented title being forgotten"))
        }
    }

    @Test func historyNeverFollowsALinkOrBlocksOnAFIFO() throws {
        let (c, folder) = try adopted()
        let log = folder.appendingPathComponent(".sprava/ops.ndjson")
        #expect(try call(c, [("command", .str("history")), ("binder", .string(folder.path))])["ok"] == .bool(true))
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: try outsideLog())
        let linked = try call(c, [("command", .str("history")), ("binder", .string(folder.path))])
        #expect(linked["ok"] == .bool(false))
        #expect(!JSONWriter.compact(linked).contains("Invented outside title"))
        try FileManager.default.removeItem(at: log)
        #expect(mkfifo(log.path, 0o600) == 0)
        #expect(try call(c, [("command", .str("history")), ("binder", .string(folder.path))])["ok"] == .bool(false))
    }

    @Test func anOwnerRecordThatIsNotAFileCountsAsDamaged() throws {
        let (c, folder) = try adopted()
        let owner = folder.appendingPathComponent(".sprava/owner.json")
        let drop: [(String, JSONValue)] = [("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("drop")),
                                           ("args", .obj([("id", .str("estate-example-2026-007")), ("closed_at", .str("2026-10-07T09:00:00Z")),
                                                          ("source", .str("user"))]))]
        // A FIFO is neither waited on nor taken for a record naming this Mac.
        try FileManager.default.removeItem(at: owner)
        #expect(mkfifo(owner.path, 0o600) == 0)
        let r = try call(c, drop)
        #expect(r["ok"] == .bool(false) && r["error"]?.stringValue?.contains("missing or damaged") == true, "\(r)")
        #expect(try list(c, folder)["ok"] == .bool(true))
        // A link to a record outside the binder that names this Mac is not followed either.
        try FileManager.default.removeItem(at: owner)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-owner-\(UUID().uuidString).json")
        try Data(#"{"format_version":"0","device":"dev"}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: owner, withDestinationURL: outside)
        #expect(try call(c, drop)["ok"] == .bool(false))
        // Nor is a regular file too large to be an owner record read whole.
        try FileManager.default.removeItem(at: owner)
        let padded = #"{"format_version":"0","device":"dev","padding":""# + String(repeating: "x", count: 70_000) + #""}"#
        try Data(padded.utf8).write(to: owner)
        let large = try call(c, drop)
        #expect(large["ok"] == .bool(false) && large["error"]?.stringValue?.contains("missing or damaged") == true, "\(large)")
    }

    /// A description longer than the filing list keeps is refused, and the saved one stays as it was.
    @Test func anOverlongDescriptionIsRefusedNotCut() throws {
        let (c, folder) = try adopted()
        let settings: (String) throws -> JSONValue = { d in
            try call(c, [("command", .str("binder_settings")), ("binder", .string(folder.path)), ("description", .string(d))])
        }
        #expect(try settings("Invented estate papers")["ok"] == .bool(true))
        let long = try settings(String(repeating: "Invented words ", count: 14))
        #expect(long["ok"] == .bool(false) && long["error"]?.stringValue?.contains("160") == true, "\(long)")
        let read = try call(c, [("command", .str("binder_settings")), ("binder", .string(folder.path))])
        #expect(read["description"] == .str("Invented estate papers"))
    }

    /// One owner per binder: an owner record another Sprava left when its adoption was interrupted (no op log yet)
    /// is not taken over, and neither is one that cannot be read.
    @Test func adoptionNeverTakesOverAnotherOwnersRecord() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-guard-\(UUID().uuidString)")
        let c = Commands(support: support, deviceID: "dev")
        for record in [#"{"format_version":"0","device":"other-mac"}"#, "not json"] {
            let folder = try makeTeka(fixture: "sprava-v0")
            let owner = folder.appendingPathComponent(".sprava/owner.json")
            try FileManager.default.createDirectory(at: owner.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(record.utf8).write(to: owner)
            let r = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
            #expect(r["ok"] == .bool(false) && r["error"]?.stringValue?.contains("not this Mac's") == true, "\(r)")
            #expect(try String(contentsOf: owner, encoding: .utf8) == record)
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava/ops.ndjson").path))
        }
    }

    @Test func noPrivacyCardIsWrittenWhileWritesAreBlocked() throws {
        let (c, folder) = try adopted()
        func privacyCards() -> Int {
            ProposalStore.list(in: folder).filter { $0.0.raw["provenance"]?["privacy_widening"] == .bool(true) }.count
        }
        // Disclosure raised outside Sprava, with a link at DASHBOARD.md that blocks every write.
        let catalogURL = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: catalogURL)).value.objectValue)
        var meta = try #require(catalog["meta"]?.objectValue)
        meta.set("disclosure", .str("full"))
        catalog.set("meta", .object(meta))
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: catalogURL)
        let dashboard = folder.appendingPathComponent("DASHBOARD.md")
        try? FileManager.default.removeItem(at: dashboard)
        try FileManager.default.createSymbolicLink(at: dashboard, withDestinationURL: try outsideLog())
        #expect(Teka.read(folder).writesBlocked)
        #expect(try list(c, folder)["ok"] == .bool(true))
        #expect(privacyCards() == 0)
        // Once the link is gone, the card is offered.
        try FileManager.default.removeItem(at: dashboard)
        #expect(try list(c, folder)["ok"] == .bool(true))
        #expect(privacyCards() == 1)
    }
}
