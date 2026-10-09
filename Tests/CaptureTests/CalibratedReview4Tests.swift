import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the fourth calibrated review of the capture layer: a raise to private survives a crash right after
/// any save, and reaches the items an approved capture changed. Invented data only.
@Suite(.serialized) struct CalibratedReview4Tests {
    let adapter = "11111111-2222-4333-8444-5555555555f4"
    let other = "00000000-2222-4333-8444-5555555555f4"   // swept first

    final class Taken: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var value: Bool { lock.withLock { done } }
        func set() { lock.withLock { done = true } }
    }

    static func copy(_ places: [URL], to snapshot: URL) {
        try? FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for (i, place) in places.enumerated() where FileManager.default.fileExists(atPath: place.path) {
            try? FileManager.default.copyItem(at: place, to: snapshot.appendingPathComponent("\(i)"))
        }
    }

    static func putBack(_ places: [URL], from snapshot: URL) throws {
        for (i, place) in places.enumerated() {
            if FileManager.default.fileExists(atPath: place.path) { try FileManager.default.removeItem(at: place) }
            let copy = snapshot.appendingPathComponent("\(i)")
            if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: copy, to: place) }
        }
    }

    /// Runs `step` once for every cursor save it makes, killed right after that save each time (everything written
    /// after it is put back as it was), then `recover`, and checks with `check`; every run starts from the same files.
    func everyCrashPoint(_ s: PSetup, step: () -> Void, recover: () -> Void, check: (Int) -> Void) throws {
        let places = [s.support, s.folder]
        let start = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-start-\(UUID().uuidString)")
        Self.copy(places, to: start)
        let counted = CursorCrash.saves(s.inbox.stateURL)
        step()
        let n = CursorCrash.saves(s.inbox.stateURL) - counted
        #expect(n > 1)
        for k in 1...n {
            try Self.putBack(places, from: start)
            let killed = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-killed-\(UUID().uuidString)")
            let taken = Taken()
            CursorCrash.stop(after: k, cursor: s.inbox.stateURL) { Self.copy(places, to: killed); taken.set() }
            step()
            CursorCrash.stop(after: nil, cursor: s.inbox.stateURL)
            #expect(taken.value)
            try Self.putBack(places, from: killed)
            recover()
            check(k)
        }
    }

    // MARK: - 1. A raise survives a crash right after any save

    @Test func aPrivateCopyRaisesItsChainWhereverASweepIsKilled() throws {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        try s.inbox.registerProducer(folder: other, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "K1", revision: "rev1", text: "Call the invented roofer")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        try s.inbox.file(try #require(s.inbox.unfiled().first).id, into: s.folder, commands: s.commands)
        let card = try #require(pOpen(s).first)
        // A copy of the same capture, marked private on the other device.
        _ = try pEvent(s, device: other, app: "adapter", ref: "K1", revision: "rev1", text: "Call the invented roofer") {
            $0.set("sensitivity", .str("private"))
        }
        try everyCrashPoint(s, step: { _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) },
                            recover: { _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }) { k in
            let waiting = pOpen(s).first { $0.id == card.id }
            #expect(waiting?.raw["provenance"]?["private"] == .bool(true), "killed after save \(k): the card is still in the clear")
            #expect(waiting?.ops.allSatisfy { $0["args"]?["item"]?["redact"] == .bool(true) } == true, "killed after save \(k)")
        }
    }

    @Test func aPrivateRevisionOrRetractionRaisesItsChainWhereverASweepIsKilled() throws {
        for retracted in [false, true] {
            let s = try pSetup()
            try s.inbox.registerProducer(folder: adapter, app: "adapter")
            _ = try pEvent(s, device: adapter, app: "adapter", ref: "K3", revision: "rev1", text: "Call the invented roofer")
            try bFileAndApprove(s)
            _ = try pEvent(s, device: adapter, app: "adapter", ref: "K3", revision: "rev2", text: "Call the invented roofer\nBuy the invented paint")
            _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
            let correction = try #require(pOpen(s).first)
            _ = try pEvent(s, device: adapter, app: "adapter", ref: "K3", revision: retracted ? "retracted" : "rev3",
                           text: retracted ? "" : "Call the invented roofer\nBuy the invented paint") {
                $0.set("sensitivity", .str("private"))
                if retracted { $0.set("retracted", .bool(true)) }
            }
            try everyCrashPoint(s, step: { _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) },
                                recover: { _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }) { k in
                let items = Teka.read(s.folder).items.compactMap(\.object).filter { $0["title"] == .str("Call the invented roofer") }
                let redacting = pOpen(s).flatMap(\.ops).filter { $0["args"]?["set"]?["redact"] == .bool(true) }.compactMap { $0["args"]?["id"] }
                #expect(items.allSatisfy { $0["redact"] == .bool(true) || redacting.contains($0["id"]!) },
                        "retracted=\(retracted), killed after save \(k): the filed item is not redacted")
                let open = pOpen(s).first { $0.id == correction.id }
                #expect(open == nil || open?.raw["provenance"]?["private"] == .bool(true), "retracted=\(retracted), killed after save \(k)")
            }
        }
    }

    // MARK: - 2. A raise reaches the items an approved capture changed

    @Test func aRaiseRedactsAnItemAnApprovedCaptureChanged() throws {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        try bAddItem(s, id: "estate-example-2026-901", title: "Invented levy payment")
        let id = try pEvent(s, device: adapter, app: "adapter", ref: "K2", revision: "rev1", text: "The invented levy is now high priority")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        // The capture's card, as the clerk makes one, changes the existing item; the person approves it.
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("invented"))])
        let update = JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([
            ("id", .str("estate-example-2026-901")), ("set", .obj([("priority", .str("high"))]))]))])
        let change = Proposal.make(title: "Raise the levy's priority", actor: actor, ops: [update],
                                   provenance: JSONObject([(key: "events", value: .array([.string(id)]))]), now: pNow)
        try ProposalStore.save(change, in: s.folder)
        try s.commands.trustProposals([change.id], in: s.folder)
        _ = try TekaStore(folder: s.folder).approve(change, now: pNow)
        #expect(Teka.read(s.folder).items.compactMap(\.object).first { $0["id"] == .str("estate-example-2026-901") }?["provenance"]?["events"] == nil)

        // The capture becomes private: the item it changed gets a redaction card.
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "K2", revision: "rev2", text: "The invented levy is now high priority") {
            $0.set("sensitivity", .str("private"))
        }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let redaction = try #require(pOpen(s).first { CaptureInbox.onlyRedacts($0) })
        #expect(redaction.ops.contains { $0["args"]?["id"] == .str("estate-example-2026-901") })
    }

    // MARK: - 3. A copy from an unregistered folder that got the card belongs to the registered chain

    let unregistered = "00000000-2222-4333-8444-5555555555e0"   // not registered, swept first

    @Test func aRaiseAndACorrectionReachTheCardOfACopyFromAnUnregisteredFolder() throws {
        for corrected in [false, true] {
            let s = try pSetup()
            try s.inbox.registerProducer(folder: adapter, app: "adapter")
            let a = try pEvent(s, device: unregistered, app: "adapter", ref: "K4", revision: "rev1", text: "Call the invented roofer")
            let b = try pEvent(s, device: adapter, app: "adapter", ref: "K4", revision: "rev1", text: "Call the invented roofer")
            _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
            #expect(try s.inbox.readState().ingested[b] == "duplicate")
            let card = try #require(s.inbox.unfiled().first { $0.raw["provenance"]?["events"] == .array([.string(a)]) })
            try s.inbox.file(card.id, into: s.folder, commands: s.commands)

            // The registered producer's later revision: private with the same words, or corrected words.
            let c = try pEvent(s, device: adapter, app: "adapter", ref: "K4", revision: "rev2",
                               text: corrected ? "Call the invented roofer Monday" : "Call the invented roofer") {
                if !corrected { $0.set("sensitivity", .str("private")) }
            }
            _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
            let waiting = pOpen(s).first { $0.id == card.id }
            if corrected {
                #expect(waiting == nil, "the copy's card is withdrawn by the correction")
                #expect(s.inbox.unfiled().contains { $0.raw["provenance"]?["events"]?.arrayValue?.contains(.string(c)) == true })
            } else {
                #expect(waiting?.raw["provenance"]?["private"] == .bool(true), "the copy's card is made private")
                #expect(waiting?.ops.allSatisfy { $0["args"]?["item"]?["redact"] == .bool(true) } == true)
            }
        }
    }

    // MARK: - 4. Settling before an approval finishes a raise that failed

    @Test func settlingFinishesARaiseThatFailedBeforeTheCardIsApproved() throws {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "K5", revision: "rev1", text: "Call the invented roofer")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        try s.inbox.file(try #require(s.inbox.unfiled().first).id, into: s.folder, commands: s.commands)
        let card = try #require(pOpen(s).first)

        // The binder's cards cannot be written while the raise runs, so it stays pending.
        let proposals = ProposalStore.dir(s.folder)
        chmod(proposals.path, 0o500)
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "K5", revision: "rev2", text: "Call the invented roofer") {
            $0.set("sensitivity", .str("private"))
        }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(try s.inbox.readState().raises?.isEmpty == false)
        #expect(s.inbox.hasDeferredWork(in: s.folder))
        #expect(!s.inbox.settle(binder: s.folder, commands: s.commands, now: pNow))   // still unwritable: the approval waits
        chmod(proposals.path, 0o700)

        // Writable again: settling, before any sweep, makes the card private, and only then may it be approved.
        #expect(s.inbox.settle(binder: s.folder, commands: s.commands, now: pNow))
        let fresh = try #require(pOpen(s).first { $0.id == card.id })
        #expect(fresh.raw["provenance"]?["private"] == .bool(true))
        #expect(fresh.ops.allSatisfy { $0["args"]?["item"]?["redact"] == .bool(true) })
    }
}
