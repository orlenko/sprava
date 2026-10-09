import BinderFormat
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the sixth adversarial review of increment 1 (a resumed restore's baseline, withdrawal by a binder
/// whose name collides, digits of other scripts in untrusted text). Invented data only.
@Suite(.serialized) struct AstraReview6Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    let today = CalendarDate(year: 2026, month: 10, day: 6)!

    // MARK: - 2. A binder whose name collides still withdraws its own slice

    @Test func aCollidingBinderWithdrawsTheSliceItRecordedAndNothingElse() throws {
        let ops = BugbotOpsTests()
        let (a, spool) = try ops.readyBinder(ops.commands())
        let (b, _) = try ops.readyBinder(ops.commands())
        let slice = ops.sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(a, root: spool, now: now) else { Issue.record("not published"); return }
        #expect(HubLane.collidingFolders(Shelf.rows(registry: nil, picked: [a, b]), today: today)
                == [a.standardizedFileURL.path, b.standardizedFileURL.path])

        // At full, a colliding binder neither drains nor publishes, and that is a failure.
        let published = try Data(contentsOf: slice)
        let blocked = HubLane.sync(b, root: spool, now: now, nameCollides: true)
        #expect(blocked.failed && blocked.drained == nil && blocked.drainError == nil)
        #expect(blocked.published == .notPublished("another binder has the same name"))
        #expect(try Data(contentsOf: slice) == published)

        // B narrows: it recorded no slice, so the one under the shared name (A's) stays.
        try ops.outsideEdit(b, ops.setMeta("disclosure", .str("none")))
        #expect(HubLane.sync(b, root: spool, now: now, nameCollides: true).published == .notPublished("the binder needs attention"))
        #expect(try Data(contentsOf: slice) == published)

        // A narrows: the slice it recorded writing goes, though its name still collides.
        try ops.outsideEdit(a, ops.setMeta("disclosure", .str("none")))
        let withdrawn = HubLane.sync(a, root: spool, now: now, nameCollides: true)
        #expect(withdrawn.published == .removed && withdrawn.failed && withdrawn.drained == nil)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
        #expect(HubLane.loadCursors(a).sliceHash == nil && HubLane.loadCursors(a).sliceName == nil)
    }
}
