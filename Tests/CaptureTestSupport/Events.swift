import BinderStore
import Capture
import Foundation
import SpravaKit

// Hand-made capture events and the setup the capture tests share. Invented data only.

package let pDevice = "0f0e0d0c-0b0a-4908-8706-050403020100"

/// Each hand-made event gets a later clock than the one before, as a producer's HLC would.
package final class PClock: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    package func next() -> Int { lock.withLock { n += 1; return n } }
}
package let pClock = PClock()

package struct PSetup {
    package let commands: Commands
    package let inbox: CaptureInbox
    package let producer: CaptureProducer
    package let folder: URL
    package let support: URL

    package init(commands: Commands, inbox: CaptureInbox, producer: CaptureProducer, folder: URL, support: URL) {
        self.commands = commands
        self.inbox = inbox
        self.producer = producer
        self.folder = folder
        self.support = support
    }
}

/// A hand-made event in `device` folder (written exactly like a producer would).
package func pEvent(_ s: PSetup, device: String, app: String, ref: String, revision: String, text: String,
            extra: (inout JSONObject) -> Void = { _ in }) throws -> String {
    let folder = s.producer.root.appendingPathComponent(device)
    try AtomicFile.makePrivateFolder(folder)
    let id = UUID().uuidString.lowercased()
    var o = JSONObject()
    o.set("format", .str("sprava-capture-event"))
    o.set("format_version", .str("0"))
    o.set("id", .string(id))
    o.set("hlc", .obj([("wall_ms", .int(1_791_360_000_000)), ("counter", .int(pClock.next())), ("node", .string(device.replacingOccurrences(of: "-", with: "")))]))
    o.set("device", .obj([("id", .string(device))]))
    o.set("source", .obj([("app", .string(app)), ("kind", .str("dictation")), ("ref", .string(ref)), ("revision", .string(revision))]))
    o.set("captured_at", .str("2026-10-06T09:00:00-04:00"))
    o.set("locale", .str("en-CA"))
    o.set("text", .string(text))
    o.set("sensitivity", .str("unmarked"))
    extra(&o)
    try CaptureProducer.publish(Data(JSONWriter.pretty(.object(o)).utf8), as: folder.appendingPathComponent("\(id).json"))
    return id
}

package func pEventObj(_ text: String, extra: (inout JSONObject) -> Void = { _ in }) -> CaptureEvent {
    var o = JSONObject()
    o.set("id", .str("01a10000-0000-7000-8000-0000000000aa"))
    o.set("source", .obj([("app", .str("sprava")), ("kind", .str("text")), ("ref", .str("r")), ("revision", .str("1"))]))
    o.set("captured_at", .str("2026-10-06T09:00:00-04:00"))
    o.set("locale", .str("en-CA"))
    o.set("text", .string(text))
    o.set("sensitivity", .str("unmarked"))
    extra(&o)
    return CaptureEvent(raw: o, url: URL(fileURLWithPath: "/dev/null"), digest: "")
}

/// Adopts `folder` as the `adopt` command does (Services' `BinderCommands`): adoption, then the cards it wrote are
/// trusted. Setups use it so a capture test does not need the command layer.
package func adoptAsCommand(_ folder: URL, commands: Commands, now: Date, today: CalendarDate) throws {
    let f = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL
    let result = try Adoption.adopt(f, inRegistry: false, deviceID: commands.deviceID, today: today, now: now, client: commands.client)
    try commands.trustProposals(result.proposals.map(\.id), in: f)
}
