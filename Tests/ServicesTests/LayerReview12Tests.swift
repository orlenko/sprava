import BinderFormat
import BinderStore
import Darwin
import Foundation
import Security
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the review of the Services layer (XPC peers, development identity, backup requests, trust
/// failures, persisted breakers and runtime state). Invented data only.
@Suite(.serialized) struct LayerReview12Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-layer12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 1. The XPC peer is the app's exact code, not any program signed under its identifier

    /// A copy of a system tool, signed ad hoc under `identifier`.
    func signedCopy(of tool: String, identifier: String, in dir: URL) throws -> URL {
        let copy = dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: tool), to: copy)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", "--identifier", identifier, copy.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        return copy
    }

    func satisfies(_ url: URL, _ requirement: String) throws -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        try #require(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess)
        try #require(SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess)
        return SecStaticCodeCheckValidity(code!, [], req) == errSecSuccess
    }

    @Test func onlyTheAppsOwnCodeMeetsTheRequirement() throws {
        let dir = try tempDir()
        let app = try signedCopy(of: "/usr/bin/true", identifier: XPCNames.appIdentifier, in: dir)
        let pinned = try XPCPeer.app(at: app)
        #expect(pinned.identifier == XPCNames.appIdentifier && pinned.cdhash.count == 40)
        let requirement = XPCPeer.requirement(for: pinned)
        #expect(try satisfies(app, requirement))
        // Another program signed under the app's identifier: accepted by the old identifier-only rule, not now.
        let impostor = try signedCopy(of: "/bin/echo", identifier: XPCNames.appIdentifier, in: dir)
        #expect(try satisfies(impostor, #"identifier "ca.orlenko.sprava""#))
        #expect(try !satisfies(impostor, requirement))
        // A bundle signed under another identifier pins nothing: no peer is admitted.
        let other = try signedCopy(of: "/usr/bin/true", identifier: "org.example.other", in: dir)
        #expect(throws: XPCPeer.Unverifiable.self) { try XPCPeer.app(at: other) }
        #expect(throws: XPCPeer.Unverifiable.self) { try XPCPeer.app(at: dir.appendingPathComponent("missing")) }
    }

    @Test func thePeerMustBeTheSameUserRunningTheAppsExecutable() throws {
        let dir = try tempDir()
        let app = try XPCPeer.app(at: try signedCopy(of: "/usr/bin/true", identifier: XPCNames.appIdentifier, in: dir))
        #expect(XPCPeer.accepts(peerUID: getuid(), peerPath: app.executable.path, app: app))
        #expect(!XPCPeer.accepts(peerUID: getuid() + 1, peerPath: app.executable.path, app: app))
        #expect(!XPCPeer.accepts(peerUID: getuid(), peerPath: "/tmp/elsewhere/SpravaApp", app: app))
        #expect(!XPCPeer.accepts(peerUID: getuid(), peerPath: nil, app: app))
        // The peer's path comes from its process; this test's own is an existing file.
        let mine = try #require(XPCPeer.path(of: getpid()))
        #expect(FileManager.default.fileExists(atPath: mine))
    }

    // MARK: - 2. Development commands have an identity of their own and refuse live binders

    @Test func developmentStateIsNeverTheInstalledApps() {
        let dev = DevelopmentGuard.supportDirectory(environment: ["SPRAVA_SUPPORT_DIR": "/tmp/invented/Sprava"])
        #expect(dev.path == "/tmp/invented/Sprava-dev")
        #expect(DevelopmentGuard.supportDirectory(environment: [:]).lastPathComponent == "Sprava-dev")
    }

    @Test func developmentCommandsRefuseShelfAndOwnedBinders() throws {
        let root = try tempDir()
        let production = root.appendingPathComponent("Support", isDirectory: true)
        let registry = root.appendingPathComponent("no-registry.toml")
        let binder = try makeTeka(fixture: "lifeproj-v2-live")
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production) == nil)

        // On the installed app's Shelf (a binder Sprava created is there, not in lifeproj's registry).
        try ShelfStore(supportDirectory: production).add(binder)
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production)?.contains("Shelf") == true)
        try ShelfStore(supportDirectory: production).remove(binder)

        // Owned by the installed app.
        let installed = try DeviceID.load(support: production)
        let owner = binder.appendingPathComponent(".sprava/owner.json")
        try FileManager.default.createDirectory(at: owner.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"device":"\#(installed)"}"#.utf8).write(to: owner)
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production)?.contains("installed Sprava") == true)
        // Owned by the development identity: allowed.
        try Data(#"{"device":"\#(UUID().uuidString.lowercased())"}"#.utf8).write(to: owner)
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production) == nil)

        // A Shelf that cannot be read might list it.
        try Data("not json".utf8).write(to: production.appendingPathComponent("shelf.json"))
        #expect(DevelopmentGuard.refusal(for: binder, registryURL: registry, productionSupport: production)?.contains("cannot be read") == true)
    }

    // MARK: - 3. Backup repository work never holds the command queue

    @Test func aStalledPeekLeavesTheCommandQueueFree() throws {
        let watch = WatchBox(budgets: RequestQueues.budgets)
        let queues = RequestQueues(watch: watch)
        let release = DispatchSemaphore(value: 0)
        let pingDone = DispatchSemaphore(value: 0)
        let peekDone = DispatchSemaphore(value: 0)
        queues.submit(#"{"command":"peek","backup_id":"x","path":"a.pdf"}"#, handle: { _ in
            release.wait()
            return #"{"ok":true}"#
        }) { _, command, _ in
            #expect(command == "peek")
            peekDone.signal()
        }
        queues.submit(#"{"command":"ping"}"#, handle: { _ in #"{"ok":true}"# }) { _, _, _ in pingDone.signal() }
        #expect(pingDone.wait(timeout: .now() + 5) == .success)
        // The stalled request is named to the watchdog while it runs.
        #expect(watch.runningFor("app_backup_request") != nil)
        #expect(watch.runningFor("app_request") == nil)
        release.signal()
        #expect(peekDone.wait(timeout: .now() + 5) == .success)
        queues.repository.sync {}
        #expect(watch.runningFor("app_backup_request") == nil)
        #expect(RequestQueues.repositoryCommands == ["peek", "backup_setup", "backup_second", "backup_status"])
    }

    // MARK: - 4. A card whose digest could not be recorded is kept by its exact digest and recorded later

    @Test func aFailedTrustIsReportedAndRetriedByTheDigestWritten() throws {
        let ops = BugbotOpsTests()
        let c = ops.commands()
        let (folder, _) = try ops.readyBinder(c)
        let catalogURL = folder.appendingPathComponent("catalog.json")
        let before = try Data(contentsOf: catalogURL)
        let card = Proposal.make(title: "Drop", actor: ops.user, ops: [ops.body("drop", .obj([
            ("id", .str("item-0006")), ("closed_at", .str("2026-10-06T08:00:00Z")), ("source", .str("user"))]))], now: now)
        try ProposalStore.save(card, in: folder)
        try TekaStore(folder: folder).approve(card, now: now)
        try before.write(to: catalogURL)   // another program puts the old copy back

        // Sprava's record of the cards cannot be read.
        let digests = c.support.appendingPathComponent("runtime/proposal-digests.json")
        let recorded = try Data(contentsOf: digests)
        try Data("not json".utf8).write(to: digests)
        let rows = Shelf.rows(registry: nil, picked: [folder])
        let listed = Set(ProposalStore.list(in: folder).map(\.0.id))
        let backlog = TrustBacklog(support: c.support)
        let first = OutsideEdits.settleAndTrust(rows, commands: c, backlog: backlog, now: now) { $0() }
        #expect(first.cards == 1 && first.untrusted == 1 && first.unsettled == 0)
        #expect(DashboardJob.outcome(DashboardJob.Result(), settled: first) == .error(code: "trust_failed", culprit: "1 card(s)"))
        let id = try #require(ProposalStore.list(in: folder).map(\.0.id).first { !listed.contains($0) })
        #expect(FileManager.default.fileExists(atPath: backlog.url.path))

        // Still unreadable: the next pass makes no new card and still fails. While the outside edit is the binder's
        // last op, BinderStore writes the same card again from the log (same id, same bytes) for the caller to trust.
        let cardURL = folder.appendingPathComponent(".sprava/proposals/\(id).json")
        let original = try Data(contentsOf: cardURL)
        try (original + Data("\n".utf8)).write(to: cardURL)
        let second = OutsideEdits.settleAndTrust(rows, commands: c, backlog: backlog, now: now) { $0() }
        #expect(second.cards == 1 && second.untrusted == 1)
        #expect(ProposalStore.list(in: folder).map(\.0.id).filter { !listed.contains($0) } == [id])
        #expect(try Data(contentsOf: cardURL) == original)

        // Repaired, but the card was changed in between: neither the new bytes nor the digest Sprava wrote is
        // recorded (BinderStore's trustChecked checks the file first), and the card leaves the backlog untrusted.
        // An op of the person's follows the outside edit first, so the card is no longer written again from the log.
        try TekaStore(folder: folder).apply([.init(op: "update_item", args: JSONObject([
            (key: "id", value: .str("item-0006")), (key: "set", value: .obj([("priority", .str("high"))]))]), actor: ops.user)], now: now)
        try recorded.write(to: digests)
        let file = folder.appendingPathComponent(".sprava/proposals/\(id).json")
        let written = try Data(contentsOf: file)
        try (written + Data("\n".utf8)).write(to: file)
        let third = OutsideEdits.settleAndTrust(rows, commands: c, backlog: backlog, now: now) { $0() }
        #expect(third.untrusted == 0)
        #expect(!FileManager.default.fileExists(atPath: backlog.url.path))
        #expect(!c.isTrusted(id, in: folder))
        try written.write(to: file)
        #expect(!c.isTrusted(id, in: folder))
        #expect(try c.loadDigests()[c.key(folder, id)] == nil)

        // A fresh backlog (a restart) also finds what the file kept.
        try Data("not json".utf8).write(to: digests)
        #expect(throws: (any Error).self) { try TrustBacklog(support: c.support).trust([id], in: folder, commands: c) }
        try recorded.write(to: digests)
        try TrustBacklog(support: c.support).retry(commands: c)
        #expect(c.isTrusted(id, in: folder))
    }

    @Test func aBacklogNeverTrustsACardThisProcessDidNotWrite() throws {
        let ops = BugbotOpsTests()
        let c = ops.commands()
        let (folder, _) = try ops.readyBinder(c)
        // A card another program dropped into the binder.
        let card = Proposal.make(title: "Dropped in", actor: ops.user, ops: [ops.body("drop", .obj([
            ("id", .str("item-0006")), ("closed_at", .str("2026-10-06T08:00:00Z")), ("source", .str("user"))]))], now: now)
        let dir = folder.appendingPathComponent(".sprava/proposals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(JSONWriter.pretty(.object(card.raw)).utf8).write(to: dir.appendingPathComponent("\(card.id).json"))
        let backlog = TrustBacklog(support: c.support)
        #expect(throws: TrustBacklog.NotWrittenHere.self) { try backlog.trust([card.id], in: folder, commands: c) }
        #expect(!c.isTrusted(card.id, in: folder))
        #expect(backlog.count == 0)
        #expect(!FileManager.default.fileExists(atPath: backlog.url.path))
    }

    // MARK: - Dashboard state that cannot be read is the job's error; other binders still render

    @Test func anUnreadableDashboardRecordFailsTheJobNotTheOtherBinders() throws {
        let ops = BugbotOpsTests()
        let c = ops.commands()
        let (a, _) = try ops.readyBinder(c)
        let (b, _) = try ops.readyBinder(c)
        let rows = Shelf.rows(registry: nil, picked: [a, b])
        let r = DashboardJob.run(rows, deviceID: c.deviceID) { folder in
            if folder.standardizedFileURL.path == a.standardizedFileURL.path {
                throw StateFile.Unreadable(path: folder.appendingPathComponent(".sprava/dashboard.json").path)
            }
            return .rendered(editedOutsideNotes: false)
        }
        #expect(r.rendered == 1 && r.failed == 1 && r.unreadable == 1)
        #expect(DashboardJob.outcome(r, settled: OutsideEdits.Settled()) == .error(code: "dashboard_state_unreadable", culprit: "1 binder(s)"))
        // A failed write (an AtomicFile flush) is a plain failure.
        let w = DashboardJob.run(rows, deviceID: c.deviceID) { _ in throw AtomicFile.Failure(step: "fsync", code: EIO) }
        #expect(DashboardJob.outcome(w, settled: OutsideEdits.Settled()) == .error(code: "dashboard_failed", culprit: "2 binder(s)"))
        // Binders another Mac owns are not this job's.
        #expect(DashboardJob.run(rows, deviceID: "another") { _ in .rendered(editedOutsideNotes: false) } == DashboardJob.Result())
    }

    // MARK: - 5. Persisted breakers this code could not have written are set aside, never indexed

    @Test func anOutOfRangeBreakerIsSetAsideAtStart() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("breakers.json")
        for bad in [#""breaker":"open","breakerOpenedAt":"2026-10-06T08:00:00Z","backoffStep":-1"#,
                    #""breaker":"open","breakerOpenedAt":"2026-10-06T08:00:00Z","backoffStep":9"#,
                    #""breaker":"open""#, #""breaker":"ajar""#, #""consecutiveFailures":-3"#] {
            try Data(#"{"jobs":{"hub":{\#(bad)}}}"#.utf8).write(to: url)
            let (records, aside) = JobRecords.loadAtStart(url, jobs: ["hub", "capture"], now: now)
            let kept = try #require(aside, "\(bad)")
            #expect(FileManager.default.fileExists(atPath: kept.path))
            #expect(records.jobs["hub"]?.breaker == "half_open" && records.jobs["capture"]?.breaker == "half_open")
            try FileManager.default.removeItem(at: kept)
        }
        // In memory, a step out of range waits the nearest backoff instead of crashing.
        var record = JobRecord()
        record.breaker = "open"
        record.breakerOpenedAt = now
        record.backoffStep = -1
        let early = record.mayRun(now: now.addingTimeInterval(30))
        let later = record.mayRun(now: now.addingTimeInterval(61))
        #expect(!early && later)
    }

    // MARK: - 6. Runtime state that cannot be read is kept, never saved over

    @Test func unreadableRuntimeStateIsSetAsideAndNeverRepeatsTheSummary() throws {
        let dir = try tempDir()
        let url = RuntimeState.url(dir)
        let garbage = Data("{\"day\": 7".utf8)
        try garbage.write(to: url)
        #expect(throws: StateFile.Unreadable.self) { try RuntimeState.read(dir) }
        // A change before the start (a lease refusal) is dropped, never saved over the file.
        #expect(!RuntimeState.recordRefusal(dir))
        #expect(try Data(contentsOf: url) == garbage)

        let (state, aside) = RuntimeState.loadAtStart(dir, now: now)
        let kept = try #require(aside)
        #expect(try Data(contentsOf: kept) == garbage)
        let today = CalendarDate.today(now: now).description
        #expect(state.lastSummaryDate == today && state.startsToday == 0)
        // The file is gone, so counting starts again.
        #expect(RuntimeState.recordStart(dir))
        #expect(try RuntimeState.read(dir).startsToday == 1)
        // A missing file is a fresh state; a file from before a field existed still reads.
        try Data(#"{"day":"2026-10-06","startsToday":2}"#.utf8).write(to: url)
        #expect(try RuntimeState.read(dir, today: "2026-10-06").startsToday == 2)
    }
}
