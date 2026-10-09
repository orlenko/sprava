import BinderStore
@testable import Brains
import Capture
import CaptureTestSupport
import Darwin
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

// Regression tests for the third hostile review (increments 4 to 6). Invented data only.

func pSetup() throws -> PSetup {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-probe3-\(UUID().uuidString)")
    let support = base.appendingPathComponent("support")
    let root = base.appendingPathComponent("capture")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    chmod(root.path, 0o700)
    let commands = Commands(support: support, deviceID: "dev")
    let folder = try makeTeka(fixture: "sprava-v0")
    try adoptAsCommand(folder, commands: commands, now: pNow, today: today)
    for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: pNow) }
    let inbox = CaptureInbox(root: root, support: support)
    try inbox.registerProducer(folder: pDevice, app: "sprava")
    return PSetup(commands: commands, inbox: inbox, producer: CaptureProducer(root: root, deviceID: pDevice, support: support),
                  folder: folder, support: support)
}

func pOpen(_ s: PSetup) -> [Proposal] { ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" } }

@Suite(.serialized) struct ReviewRegression3Tests {
    // MCP: a brain's new item needs a placeholder id; ops must be objects.
    @Test func r19_mcpPlaceholdersAndOps() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sp3n-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "t")
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: pNow)
        let client = MCPClientRecord(id: "c1", name: "c", tokenSHA256: "", binders: [folder.standardizedFileURL.path: "propose"], createdAt: "", revoked: false)
        let server = MCPServer(client: client, commands: commands, shelf: { Shelf.rows(registry: nil, picked: [folder]) }, now: { pNow })
        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
        let a = try JSONParser.parse(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"estate-example","title":"x","ops":[{"op":"add_item","args":{"item":{"id":77,"title":"Chosen id","status":"open","priority":"normal","no_deadline":true}}}]}}}"#)!).value
        #expect(a["result"]?["isError"] == .bool(true))
        let b = try JSONParser.parse(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"estate-example","title":"empty","ops":[1]}}}"#)!).value
        #expect(b["result"]?["isError"] == .bool(true))
    }
}
