import BinderFormat
import Foundation
import Services
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
        let row = try Self.row(fixture: "lifeproj-v2-fresh", "old-boat")
        #expect(!row.teka.isAdopted)
        if row.teka.state == .ready || row.teka.state == .needsMigration {
            #expect(ShelfRowView.signal(row, chase: 1) == .init(tone: .quiet, words: "not yet adopted"))
        }
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
