import BinderFormat
import BinderStore
import Brains
import Capture
import CaptureTestSupport
import Darwin
import Foundation
@testable import Services
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

func pRows(_ s: PSetup) -> [ShelfRow] { [ShelfRow(folder: s.folder, source: .picked, archived: false, teka: Teka.read(s.folder))] }
func pOpen(_ s: PSetup) -> [Proposal] { ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" } }

@Suite(.serialized) struct ReviewRegression3Tests {
    // 10. Revocation reaches an open connection at once.
    @Test func r15_aRevokedClientIsCutOff() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sp3r-\(UUID().uuidString.prefix(8))")
        let commands = Commands(support: support, deviceID: "t")
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: pNow)
        var clients = MCPClients()
        let token = try clients.register(id: "brain-1", name: "b", binders: [folder.standardizedFileURL.path: "propose"])
        try clients.save(support)
        let listener = MCPListener(support: support, commands: commands, queue: DispatchQueue(label: "q"),
                                   shelf: { Shelf.rows(registry: nil, picked: [folder]) }, log: { _ in })
        try listener.start()
        defer { listener.stop() }
        let fd = try MCPShimConnection.connect(socket: listener.socketURL.path, clientID: "brain-1", token: token).get()
        defer { close(fd) }
        let reader = LineReader(fd: fd)
        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
        func propose(_ n: Int) -> JSONValue? {
            let line = #"{"jsonrpc":"2.0","id":\#(n),"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"estate-example","title":"t\#(n)","ops":[{"op":"add_log_entry","args":{"entry":{"action":"noted","title":"x","date":"2026-10-06"}}}]}}}"#
            _ = writeLine(fd, line)
            guard case .line(let r) = reader.next(limit: 1 << 20) else { return nil }
            return try? JSONParser.parse(r).value
        }
        #expect(propose(1)?["result"]?["structuredContent"]?["proposal_id"] != nil)
        let r = try JSONParser.parse(commands.handle(#"{"command":"revoke_client","client_id":"brain-1"}"#, now: pNow)).value
        #expect(r["withdrawn"] == .int(1))
        #expect(propose(2) == nil)   // the connection is closed
    }
}
