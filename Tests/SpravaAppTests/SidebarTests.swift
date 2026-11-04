import BinderFormat
import Foundation
@testable import Services
import Shelf
@testable import SpravaApp
import SpravaKit
import SpravaTestSupport
import Testing

/// The sidebar says one thing about each binder, keeps General last, and its status line turns red for more than a stopped
/// process (decisions.md D37). Invented binders.
@MainActor
@Suite struct SidebarTests {
    typealias Facts = HealthSummary.Facts

    @Test func aRunningProcessAloneIsNotEnoughToSayRunning() {
        #expect(HealthSummary.of(Facts()).word == "Running")
        #expect(HealthSummary.of(Facts(jobs: [.green, .red])).level == .trouble)
        #expect(HealthSummary.of(Facts(backupFailed: true)).level == .trouble)
        #expect(HealthSummary.of(Facts(backupSettingsUnreadable: true)).level == .trouble)
        #expect(HealthSummary.of(Facts(backupVeryOld: true)).level == .trouble)
        for facts in [Facts(jobs: [.amber]), Facts(backupOld: true), Facts(alertsOff: true), Facts(otherFindings: true)] {
            #expect(HealthSummary.of(facts).level == .needsYou)
            #expect(HealthSummary.of(facts).sentence == nil)   // the line says so; no notice on every page
        }
    }

    @Test func aStoppedProcessSaysSoAndOffersRestart() {
        for grade in [HealthGrade.red, .unknown] {
            let summary = HealthSummary.of(Facts(runtime: grade))
            #expect(summary.level == .trouble && summary.restartHelps && summary.sentence != nil)
        }
        #expect(!HealthSummary.of(Facts(jobs: [.red])).restartHelps)
    }

    @Test func theWordsSayWhatTheGradeMeans() {
        #expect(HealthSummary.of(Facts(runtime: .amber)).word == "May be stuck")
        #expect(HealthSummary.of(Facts(runtime: .waking)).word == "Waking up")
        #expect(HealthSummary.of(Facts(starting: true, runtime: .red)).level == .starting)
        #expect(HealthSummary.of(Facts(needsApproval: true, runtime: .red)).word == "Needs your approval")
        #expect(HealthSummary.of(Facts(jobs: [.red, .red])).sentence?.hasPrefix("2 of") == true)
    }

    /// What the model reads, as the status line sees it. This test process does not run from an app bundle, so the
    /// location is set apart; a running, healthy Mac with an adopted binder must then say Running.
    private func model(_ checks: HealthSnapshot.Checks = HealthSnapshot.Checks(), keeper: RuntimeKeeper? = nil) async throws -> HealthModel {
        var heartbeat = Heartbeat(pid: getpid(), started_at: ISOTime.string(try #require(ProcessCheck.startTime(pid: getpid()))),
                                  beat_at: ISOTime.string(Date()), last_wake_at: nil, build: "0.1.0 (2)", xpc_protocol: 1,
                                  lease: .init(inode: 9, duplicates_refused_today: 0), restarts_today: 0, alerts: nil,
                                  runtime_key: nil, stage_crashes: [:], model: nil, outbound_today: [:], jobs: [:])
        heartbeat.alerts = .init(authorized: true, checked_at: ISOTime.string(Date()))
        var records = HealthSnapshot.Runtime()
        records.heartbeat = .success(heartbeat)
        let runtime = records
        var reads = HealthModel.Reads()
        reads.runtime = { _ in runtime }
        reads.checks = { _ in checks }
        let model = HealthModel(support: try temporaryFolder(), reads: reads, keeper: keeper,
                                client: RuntimeClient(answer: { _ in #"{"ok":true}"# }))
        model.refresh()
        await model.settled()
        model.runtimeStatus = .enabled
        return model
    }

    private func word(_ model: HealthModel) -> String {
        var facts = model.summaryFacts
        facts.misplaced = false
        return HealthSummary.of(facts).word
    }

    /// The app reads its checks with no hub folder, so every adopted binder brings a finding about the whole Mac.
    @Test func findingsAboutTheWholeMacDoNotKeepTheLineFromSayingRunning() async throws {
        var checks = HealthSnapshot.Checks()
        checks.findings = Doctor.run(rows: [try Self.adopted(fixture: "sprava-v0")], deviceID: nil, registry: nil,
                                     support: try temporaryFolder())
        #expect(checks.findings.contains { $0.level == .fix && $0.binder == nil })
        #expect(word(try await model(checks)) == "Running")
        checks.findings.append(.init(level: .fix, binder: "Garden shed", text: "invented", next: Doctor.noFix))
        #expect(word(try await model(checks)) == "Needs a look")
    }

    @Test func aFailedRestartIsNotRunningEvenWithTheOldProcessBeating() async throws {
        let keeper = RuntimeKeeper(system: .init(registration: { .enabled }, live: { _ in false }, start: { _ in "Invented failure" }))
        keeper.beatWait = .milliseconds(100)
        keeper.poll = .milliseconds(20)
        let model = try await model(keeper: keeper)
        #expect(word(model) == "Running")
        _ = await keeper.restart()
        await model.settled()
        model.runtimeStatus = .enabled
        #expect(model.startFailure != nil)
        #expect(model.summary.level == .trouble && model.summary.restartHelps)
    }

    @Test func runningFromTheWrongPlaceAsksForALook() {
        #expect(HealthSummary.of(Facts(misplaced: true)).word == "Needs a look")
    }

    /// Before the launch's first read the model holds its defaults; the line says Starting, not Not running.
    @Test func theLaunchIsStartingNotStopped() async throws {
        let keeper = RuntimeKeeper(system: .init(registration: { .enabled }, live: { _ in false }, start: { _ in nil }))
        keeper.beginLaunch()
        var reads = HealthModel.Reads()
        reads.runtime = { _ in HealthSnapshot.Runtime() }
        reads.checks = { _ in HealthSnapshot.Checks() }
        let model = HealthModel(support: try temporaryFolder(), reads: reads, keeper: keeper)
        #expect(model.summary.level == .starting)
    }

    /// The dot on the Health page and the status line come from one grade.
    @Test func theBackupDotAndTheLineAgree() async throws {
        let day: TimeInterval = 86_400
        func checks(at: Date?, error: String? = nil, configured: Bool = true) -> HealthSnapshot.Checks {
            var checks = HealthSnapshot.Checks()
            checks.backupConfigured = configured
            checks.backups = [.init(name: "Garden shed", at: at, error: error)]
            return checks
        }
        let never = try await model(checks(at: nil))
        #expect(never.grade(never.backups[0]) == .unknown && word(never) == "Running")
        let today = try await model(checks(at: Date()))
        #expect(today.grade(today.backups[0]) == .green && word(today) == "Running")
        let old = try await model(checks(at: Date().addingTimeInterval(-3 * day)))
        #expect(old.grade(old.backups[0]) == .amber && word(old) == "Needs a look")
        let veryOld = try await model(checks(at: Date().addingTimeInterval(-8 * day)))
        #expect(veryOld.grade(veryOld.backups[0]) == .red && veryOld.summaryFacts.backupVeryOld && word(veryOld) == "Trouble")
        let failed = try await model(checks(at: Date(), error: "invented"))
        #expect(failed.grade(failed.backups[0]) == .red && failed.summaryFacts.backupFailed && word(failed) == "Trouble")
        // Backup turned off: an old record of it says nothing any more.
        let off = try await model(checks(at: Date().addingTimeInterval(-8 * day), error: "invented", configured: false))
        #expect(off.grade(off.backups[0]) == .unknown && word(off) == "Running")
    }

    @Test func anOrdinaryBinderIsSilentAndAChaseIsSaid() throws {
        let row = try Self.adopted(fixture: "sprava-v0")
        #expect(row.teka.state == .ready && row.teka.isAdopted)
        #expect(ShelfRowView.signal(row, chase: 0) == nil)
        #expect(ShelfRowView.signal(row, chase: 2) == .init(tone: .needsYou, words: "2 to chase"))
    }

    /// An adopted binder with a damaged catalog must not look like an ordinary one.
    @Test func anAdoptedBinderThatNeedsMigrationSaysSo() throws {
        let row = try Self.adopted(fixture: "lifeproj-v2-live")
        #expect(row.teka.state == .needsMigration && row.teka.isAdopted)
        #expect(ShelfRowView.signal(row, chase: 1) == .init(tone: .needsYou, words: row.stateLabel))
    }

    @Test func aBinderNotYetAdoptedSaysSoQuietly() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        let row = ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))
        #expect(!row.teka.isAdopted && row.teka.state == .ready)
        #expect(ShelfRowView.signal(row, chase: 1) == .init(tone: .quiet, words: row.stateLabel))
    }

    @Test func aBinderThatIsNotAReadyOneAlwaysSaysSoAboveAChase() throws {
        let plain = try temporaryFolder()
        let row = ShelfRow(folder: plain, source: .picked, archived: false, teka: Teka.read(plain))
        let signal = try #require(ShelfRowView.signal(row, chase: 3))
        #expect(signal.words == row.stateLabel && !signal.words.contains("chase"))
        #expect(signal.tone != .needsYou || row.teka.state != .ready)
    }

    @Test func generalComesLastWhateverItsPlace() throws {
        let rows = try ["general-2", "garden-shed", "tax-2026"].map { try Self.row(fixture: "sprava-v0", $0) }
        let listed = ShelfModel.generalLast(rows, general: rows[0].folder).map(\.folder)
        #expect(listed == [rows[1].folder, rows[2].folder, rows[0].folder])
        #expect(ShelfModel.generalLast(rows, general: nil).map(\.folder) == rows.map(\.folder))
    }

    /// General is known by its binding: creation can choose general-2, and a binder merely named general is not it.
    @Test func theShelfKnowsGeneralByItsBindingNotItsName() async throws {
        let support = try temporaryFolder()
        let named = try makeTeka(fixture: "sprava-v0", folderName: "general")
        let bound = try makeTeka(fixture: "sprava-v0", folderName: "general-2")
        let store = try ShelfStore(supportDirectory: support)
        try store.add(named)
        try store.add(bound)
        _ = try GeneralBinder(support: support).ensure { bound }
        let model = ShelfModel(support: support, client: StandInRuntime().client, deadline: ManualDeadlines().deadline)
        await model.refreshAndWait()
        #expect(model.general?.lastPathComponent == "general-2")
        #expect(model.shelfRows.last?.folder.lastPathComponent == "general-2")
    }

    private static func adopted(fixture: String) throws -> ShelfRow {
        let folder = try makeTeka(fixture: fixture) { folder in
            let history = folder.appendingPathComponent(".sprava", isDirectory: true)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try Data("{\"op\":\"import_snapshot\"}\n".utf8).write(to: history.appendingPathComponent("ops.ndjson"))
        }
        return ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))
    }

    private static func row(fixture: String, _ name: String) throws -> ShelfRow {
        let folder = try makeTeka(fixture: fixture, folderName: name)
        return ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))
    }
}
