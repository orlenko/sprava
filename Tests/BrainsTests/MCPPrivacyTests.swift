import BinderFormat
import BinderStore
@testable import Brains
import Capture
import CryptoKit
import Darwin
import Extract
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// No intake document reaches a brain until the person can mark one as not private (issue #283): none is listed,
/// read, finished or answered, whatever its card says, the binder's disclosure or the client's document permission;
/// and a file_document from intake/ gets one answer, whatever file or digest it names. Invented data only.
@Suite(.serialized) struct MCPPrivacyTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])
    let clerk = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("sprava/0.1")), (key: "model", value: .str("none"))])

    /// A binder at disclosure `full` and a client that may propose there and read documents.
    func setup() throws -> (MCPServer, URL, Commands) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        _ = try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: now)
        try store.apply([.init(op: "set_disclosure", args: JSONObject([(key: "disclosure", value: .str("full"))]), actor: user)], now: now)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-brains-privacy-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "t")
        let client = MCPClientRecord(id: "claude-code-1", name: "Claude Code", tokenSHA256: "", binders: [folder.standardizedFileURL.path: "propose"],
                                     createdAt: "", revoked: false, documents: true)
        let now = self.now
        return (MCPServer(client: client, commands: commands, shelf: { Shelf.rows(registry: nil, picked: [folder]) }, now: { now }), folder, commands)
    }

    func tool(_ s: MCPServer, _ name: String, _ arguments: [(String, JSONValue)]) throws -> JSONValue {
        let line = JSONWriter.compact(.obj([("jsonrpc", .str("2.0")), ("id", .int(1)), ("method", .str("tools/call")),
                                            ("params", .obj([("_meta", .obj([("io.modelcontextprotocol/protocolVersion", .str("2026-07-28"))])),
                                                             ("name", .string(name)), ("arguments", .obj(arguments))]))]))
        let reply = try #require(s.handle(line: line))
        return try #require(try JSONParser.parse(reply).value["result"])
    }

    func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    let addItem = JSONValue.obj([("op", .str("add_item")), ("args", .obj([("item", .obj([("id", .str("$new:1")), ("title", .str("Call the notary")),
                                                                                       ("status", .str("open")), ("priority", .str("normal")),
                                                                                       ("no_deadline", .bool(true))]))]))])

    /// A file in intake/, its filing card as the clerk writes it (marked private unless `isPrivate` is false), and its
    /// reading waiting for a brain. Returns the card.
    @discardableResult
    func intake(_ name: String, text: String, isPrivate: Bool, folder: URL, commands: Commands) throws -> Proposal {
        let intake = folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: intake.appendingPathComponent(name))
        var document = JSONObject([(key: "id", value: .str("$new:1")), (key: "title", value: .str("Invented letter")),
                                   (key: "path", value: .string("correspondence/" + name)), (key: "sha256", value: .string(hex(data))),
                                   (key: "source", value: .str("intake/"))])
        if isPrivate { document.set("redact", .bool(true)) }
        let op = JSONObject([(key: "op", value: .str("file_document")),
                             (key: "args", value: .obj([("document", .object(document)), ("from", .string("intake/" + name))]))])
        var provenance = JSONObject([(key: "filed_by", value: .str("clerk"))])
        if isPrivate { provenance.set("private", .bool(true)) }
        let card = Proposal.make(title: "File \u{201C}\(name)\u{201D}", actor: clerk, ops: [op], provenance: provenance, now: now)
        try ProposalStore.save(card, in: folder)
        var e = IntakeReadings.Entry(id: "reading-" + name.replacingOccurrences(of: ".", with: "-"), binder: folder.standardizedFileURL.path,
                                     name: name, sha256: hex(data), card: card.id,
                                     reading: IntakeReading(kind: "text", textFrom: "parsed", text: text, channel: "other"), now: now)
        e.escalation = "waiting"
        e.escalate = ["governing"]
        e.result = JSONObject([(key: "class", value: .str("governing")), (key: "title", value: .str("Invented lease for " + name)),
                               (key: "summary", value: .str("An invented summary of " + name))])
        try IntakeReadings(support: commands.support).save(e)
        return card
    }

    // MARK: - 1. No intake reading is listed, read, finished or answered, marked private or not, filed or not

    @Test func noIntakeDocumentReachesABrain() throws {
        let (server, folder, commands) = try setup()
        let card = try intake("private.txt", text: "An invented private letter.", isPrivate: true, folder: folder, commands: commands)
        let open = try intake("open.txt", text: "An invented open notice.", isPrivate: false, folder: folder, commands: commands)
        let readings = IntakeReadings(support: commands.support)
        let binder = ("binder", JSONValue.str("estate-example"))

        func check() throws {
            let listed = try tool(server, "list_readings", [])
            #expect(listed["isError"] != .bool(true))
            #expect(listed["structuredContent"]?["readings"] == .array([]))
            for word in ["private.txt", "open.txt", "Invented lease", "governing"] { #expect(JSONWriter.compact(listed).contains(word) == false) }

            // A reading's id, marked private or not, gets the very bytes an id that never existed gets.
            for name in ["read_document", "finish_reading"] {
                let unknown = JSONWriter.compact(try tool(server, name, [binder, ("reading_id", .str("reading-none"))]))
                #expect(unknown.contains("not found"))
                for id in ["reading-private-txt", "reading-open-txt"] {
                    #expect(JSONWriter.compact(try tool(server, name, [binder, ("reading_id", .string(id))])) == unknown)
                }
            }
            #expect(readings.load("reading-private-txt")?.escalation == "waiting")
            #expect(readings.load("reading-open-txt")?.escalation == "waiting")

            // Nor may a proposal answer one: it is refused and stores nothing.
            let before = ProposalStore.list(in: folder).count
            let answered = try tool(server, "propose_ops", [binder, ("title", .str("Answer the notice")), ("ops", .array([addItem])),
                                                            ("reading_id", .str("reading-open-txt"))])
            #expect(answered["structuredContent"]?["error"] == .str("reading_id: not found"))
            #expect(ProposalStore.list(in: folder).count == before)
        }
        try check()   // while the cards wait

        _ = try TekaStore(folder: folder).approve(card, now: now)
        _ = try TekaStore(folder: folder).approve(open, now: now)
        let paths = Teka.read(folder).catalog?["documents"]?.arrayValue?.compactMap { $0["path"]?.stringValue } ?? []
        #expect(paths.contains("correspondence/private.txt") && paths.contains("correspondence/open.txt"))
        try check()   // and once both are filed
    }

    // MARK: - 2. A file_document from intake/ gets one answer, whatever it names, and nothing is hashed or stored

    @Test func aFilingFromIntakeGetsOneAnswerWhateverItNames() throws {
        let (server, folder, commands) = try setup()
        let secret = "An invented private letter."
        let notice = "An invented open notice."
        try intake("private.txt", text: secret, isPrivate: true, folder: folder, commands: commands)
        try intake("open.txt", text: notice, isPrivate: false, folder: folder, commands: commands)
        // A file behind a linked folder, and a sparse file that claims 64 GiB, so hashing it would read zeros for minutes.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-brains-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let note = Data("An invented outside note.".utf8)
        try note.write(to: outside.appendingPathComponent("note.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("intake/archive"), withDestinationURL: outside)
        let huge = folder.appendingPathComponent("intake/huge.bin")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        #expect(truncate(huge.path, 64 << 30) == 0)
        let cards = ProposalStore.list(in: folder).count

        func file(_ from: String, sha: JSONValue, request: String) throws -> String {
            let op = JSONValue.obj([("op", .str("file_document")), ("args", .obj([("from", .string(from)),
                ("document", .obj([("id", .str("$new:1")), ("title", .str("Invented letter")), ("path", .str("correspondence/letter.txt")),
                                   ("sha256", sha), ("source", .str("intake/"))]))]))])
            let r = try tool(server, "propose_ops", [("binder", .str("estate-example")), ("title", .str("File a letter")),
                                                     ("ops", .array([op])), ("request_id", .string(request))])
            #expect(r["isError"] == .bool(true))
            return JSONWriter.compact(r)
        }

        let started = Date()
        let wrong = JSONValue.string(String(repeating: "0", count: 64))
        let answer = try file("intake/private.txt", sha: .string(hex(Data(secret.utf8))), request: "invented-1")
        #expect(answer.contains("brains get no intake documents"))
        let named: [(String, JSONValue)] = [
            ("intake/private.txt", wrong), ("intake/open.txt", .string(hex(Data(notice.utf8)))), ("intake/open.txt", wrong),
            ("intake/archive/note.txt", .string(hex(note))), ("intake/huge.bin", wrong), ("intake/none.txt", wrong),
            ("intake/open.txt", .str("abc")), ("intake/open.txt", .int(1)),
        ]
        for (i, (from, sha)) in named.enumerated() { #expect(try file(from, sha: sha, request: "invented-\(i + 2)") == answer, "\(from)") }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(ProposalStore.list(in: folder).count == cards)   // only the clerk's cards
    }

    // MARK: - 3. What a brain may do outside intake still works

    @Test func aBrainStillSeesItsBindersAndProposesOutsideIntake() throws {
        let (server, folder, commands) = try setup()
        try intake("open.txt", text: "An invented open notice.", isPrivate: false, folder: folder, commands: commands)
        let binders = try tool(server, "list_binders", [])
        #expect(binders["structuredContent"]?["binders"]?.arrayValue?.compactMap { $0["binder"]?.stringValue } == ["estate-example"])
        let r = try tool(server, "propose_ops", [("binder", .str("estate-example")), ("title", .str("Call the notary")), ("ops", .array([addItem]))])
        #expect(r["structuredContent"]?["state"] == .str("proposed"))
        let id = try #require(r["structuredContent"]?["proposal_id"]?.stringValue)
        #expect(try tool(server, "get_proposal", [("binder", .str("estate-example")), ("proposal_id", .string(id))])["structuredContent"]?["state"]
                == .str("proposed"))
    }
}
