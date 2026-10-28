import Foundation
@testable import SpravaApp
import SpravaKit
import Testing

/// The Backup page's Run Restore Drill: one request through the runtime's backup queue, followed until the backup job
/// finishes it. Queued is never passed, and the last drill's date comes only from the backup's own status. A stand-in
/// runtime and invented paths only; no repository, Keychain or registration.
@MainActor
@Suite struct BackupDrillTests {
    /// The runtime as the page sees it: status from a queue the test moves along, and backup_request answered as the
    /// queue answers it, the same request again while one is pending.
    @MainActor
    final class StandIn {
        var configured = true
        var lastDrill: String?
        var queue: [(id: String, state: String, message: String?)] = []
        var refusal: String?
        var sent: [JSONValue] = []

        lazy var client = RuntimeClient(answer: { [self] text in
            let r = try JSONParser.parse(text).value
            if r["command"] == .str("backup_request") {
                sent.append(r)
                if let refusal { return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .string(refusal))])) }
                if let pending = queue.first(where: { BackupModel.pendingStates.contains($0.state) }) {
                    return JSONWriter.compact(.obj([("ok", .bool(true)), ("request", .string(pending.id))]))
                }
                let id = "drill-\(queue.count + 1)"
                queue.append((id, "queued", nil))
                return JSONWriter.compact(.obj([("ok", .bool(true)), ("request", .string(id))]))
            }
            let requests = queue.map { q in JSONValue.obj([("id", .string(q.id)), ("kind", .str("drill")), ("state", .string(q.state)),
                                                           ("binder", .str("/Invented/estate-example")),
                                                           ("message", q.message.map(JSONValue.string) ?? .null)]) }
            return JSONWriter.compact(.obj([("ok", .bool(true)), ("configured", .bool(configured)), ("primary", .str("/Invented/Mirror")),
                                            ("last_drill", lastDrill.map(JSONValue.string) ?? .null), ("binders", .array([])),
                                            ("requests", .array(requests))]))
        })

        func finish(_ state: String, _ message: String?) {
            queue[queue.count - 1].state = state
            queue[queue.count - 1].message = message
        }
    }

    let binder = URL(fileURLWithPath: "/Invented/estate-example", isDirectory: true)

    @Test func aDrillIsQueuedWithItsBinderAndFollowedUntilItPasses() async throws {
        let runtime = StandIn()
        let model = BackupModel(client: runtime.client)
        await model.load()
        #expect(model.canRunDrill(binder))
        await model.runDrill(binder)
        let sent = try #require(runtime.sent.first)
        #expect(sent == .obj([("command", .str("backup_request")), ("kind", .str("drill")), ("binder", .str("/Invented/estate-example")),
                              ("repository", .str("primary"))]))
        #expect(model.drillRequest == "drill-1" && model.message == nil)
        // Accepted is not passed: the page says queued, and the last drill is still never.
        #expect(model.drillStatus == "Restore drill queued. It runs in the background; this page shows its result.")
        #expect(model.lastDrill == nil && !model.canRunDrill(binder))
        runtime.finish("running", nil)
        await model.load()
        #expect(model.drillStatus == "Restore drill running\u{2026}")
        #expect(model.lastDrill == nil)
        runtime.finish("done", "the restore drill passed")
        runtime.lastDrill = "2026-10-28T09:30:00Z"
        await model.load()
        #expect(model.drillStatus == "Restore drill passed.")
        #expect(model.lastDrill == "2026-10-28T09:30:00Z")
        #expect(model.canRunDrill(binder))
    }

    /// While a drill is pending, from this page or queued before, no second one is sent.
    @Test func aPendingDrillIsNotQueuedTwice() async {
        let runtime = StandIn()
        runtime.queue = [("earlier", "queued", nil)]
        let model = BackupModel(client: runtime.client)
        await model.load()
        #expect(!model.canRunDrill(binder))
        #expect(model.drillStatus == "Restore drill queued. It runs in the background; this page shows its result.")
        await model.runDrill(binder)
        #expect(runtime.sent.isEmpty)
        // Two clicks before the first answer send one request.
        runtime.queue = []
        await model.load()
        async let first: Void = model.runDrill(binder)
        async let second: Void = model.runDrill(binder)
        _ = await (first, second)
        #expect(runtime.sent.count == 1)
    }

    @Test func itIsOfferedOnlyOnceBackupIsSetUpAndABinderIsChosen() async {
        let runtime = StandIn()
        runtime.configured = false
        let model = BackupModel(client: runtime.client)
        #expect(!model.canRunDrill(binder))   // the runtime has not answered yet
        await model.load()
        #expect(!model.canRunDrill(binder))
        await model.runDrill(binder)
        #expect(runtime.sent.isEmpty)
        runtime.configured = true
        await model.load()
        #expect(!model.canRunDrill(nil))
        #expect(model.canRunDrill(binder))
    }

    @Test func aRefusalSaysWhyAndQueuesNothing() async {
        let runtime = StandIn()
        runtime.refusal = "this binder is not managed by this Mac"
        let model = BackupModel(client: runtime.client)
        await model.load()
        await model.runDrill(binder)
        #expect(model.message == "The restore drill was not started: this binder is not managed by this Mac")
        #expect(model.drillRequest == nil && model.drillStatus == nil && model.lastDrill == nil)
        #expect(model.canRunDrill(binder))
    }

    @Test func aFailedDrillShowsTheBackupJobsReasonAndNoNewDate() async {
        let runtime = StandIn()
        runtime.lastDrill = "2026-09-01T08:00:00Z"
        let model = BackupModel(client: runtime.client)
        await model.load()
        await model.runDrill(binder)
        runtime.finish("failed", "no snapshot to restore")
        await model.load()
        #expect(model.drillStatus == "Restore drill failed: no snapshot to restore")
        #expect(model.lastDrill == "2026-09-01T08:00:00Z")
        #expect(model.canRunDrill(binder))
    }
}
