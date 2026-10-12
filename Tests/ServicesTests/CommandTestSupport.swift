import BinderFormat
import BinderStore
import Capture
import CaptureTestSupport
import Darwin
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport

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

func pOpen(_ s: PSetup) -> [Proposal] { ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" } }
