import BinderFormat
import BinderStore
import Capture
import CaptureTestSupport
import Darwin
import CryptoKit
import Foundation
import Hub
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// An adopted invented binder with its adoption cards rejected, a capture inbox and a registered producer, behind a
/// command table: the starting point of the command tests. Temporary folders only.
func pSetup() throws -> PSetup {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-commands-\(UUID().uuidString)")
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

/// The binder's agenda slice items, as the hub would publish them.
func bSlice(_ folder: URL) throws -> [JSONValue] {
    let catalog = try #require(Teka.read(folder).catalog)
    let (slice, _) = try HubLane.project(catalog: catalog, folderName: folder.lastPathComponent, closedOnce: [],
                                         key: SymmetricKey(size: .bits256), now: pNow)
    return slice["items"]?.arrayValue ?? []
}

/// Adds a public open item by hand, as the person would.
func bAddItem(_ s: PSetup, id: String, title: String, extra: [(String, JSONValue)] = [("no_deadline", .bool(true))]) throws {
    let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("t"))])
    _ = try TekaStore(folder: s.folder).apply([.init(op: "add_item", args: JSONObject([(key: "item", value: .obj([
        ("id", .string(id)), ("title", .string(title)), ("status", .str("open")), ("priority", .str("normal"))] + extra))]), actor: actor)], now: pNow)
}
