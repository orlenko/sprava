import BinderFormat
import BinderStore
import Companion
import Foundation
import Shelf
import SpravaKit

extension CompanionJob {
    /// The runtime's companion job: after owner recovery admits a claimed relay, one publishing pass over the
    /// shown binders of the Shelf, then one drain of the phones' requests and their outcomes (companion-v0 §9.2).
    static func publishing(session: CompanionOwnerSession, database: URL, secrets: any CompanionCredentialStorage,
                           support: URL, deviceID: String) -> CompanionJob {
        let publishing = CompanionPublishing(support: support, deviceID: deviceID)
        let draining = CompanionDraining(support: support, deviceID: deviceID)
        return CompanionJob(session: session) { locks in
            guard let profile = try CompanionProfile.openConfigured(database: database, secrets: secrets) else { return }
            // The throwing read: an unreadable Shelf is a job failure, never an empty Shelf that hides every binder.
            let rows = try ShelfStore(supportDirectory: support).rowsForJobs()
            try await cycle(publishing: publishing, draining: draining, profile: profile, locks: locks,
                            target: try CompanionOwnerPublication(profile: profile), rotation: session.rotation(profile), rows: rows)
        }
    }

    /// Relay calls one run spends on a removal's relay work and new keys (§4.4), each bounded to 30 seconds.
    static let rotationCalls = 20

    /// One run's work: a removal's relay work and new keys first (§4.4), then publish, drain, and publish again
    /// when the drain changed a binder, so what the phones did reaches their views in this run (§9.7). A keys object
    /// the relay refused fails the run after its work, so Health names it until the person's Retry.
    static func cycle(publishing: CompanionPublishing, draining: CompanionDraining, profile: CompanionProfile,
                      locks: CompanionDeviceDecisionLocks, target: any CompanionPublishingTarget & CompanionOutcomesTarget,
                      rotation: @escaping @Sendable () async throws -> CompanionRotationProgress,
                      rows: [ShelfRow], timeZone: TimeZone = .current, clock: @escaping @Sendable () -> Date = { Date() }) async throws {
        await CompanionRemovalActions.advance(profile, limit: rotationCalls, step: rotation)
        _ = try await publishing.run(profile: profile, target: target, rows: rows, now: clock(), timeZone: timeZone)
        let drained = try await draining.run(profile: profile, locks: locks, outcomes: target, timeZone: timeZone, clock: clock)
        if drained.decisionsCommitted > 0 {
            _ = try await publishing.run(profile: profile, target: target, rows: rows, now: clock(), timeZone: timeZone)
        }
        if try profile.rotationFault() { throw CompanionJobFault.rotationRefused }
    }
}

/// A fault the companion job reports on Health after doing what it could.
enum CompanionJobFault: Error, Equatable {
    /// The relay refused a phone's new keys after a removal; publication waits for the person's Retry (§4.4, §9.7).
    case rotationRefused
}

/// The part of the owner's publisher the companion job uses; tests stand in for the relay through it.
protocol CompanionPublishingTarget: Sendable {
    func uploadView(binderID: String) async throws -> CompanionPublicationProgress
    func uploadIndex(generatedAt: String) async throws -> CompanionPublicationProgress
    func cleanRemovedBinders(limit: Int) async throws -> Int
}
extension CompanionOwnerPublication: CompanionPublishingTarget {}

/// What one publishing pass did, by count only: logs never carry binder names, ids or titles.
struct CompanionPublishingReport: Sendable, Equatable {
    var snapshots = 0, uploads = 0, skipped = 0, hidden = 0, indexes = 0, deletions = 0
    /// Nothing was published: a rotation's keys are not all on the relay yet (§4.4).
    var held = false
}

/// companion-v0 §9.7 for the runtime: each shown binder's view, the index, and the cleanup of a binder switched off.
/// One instance per runtime; it remembers, in memory, what each binder's last snapshot read, so a binder is snapshot
/// again only when its catalog or the day changed (a restart snapshots each shown binder once). It never runs twice
/// at a time: `CompanionJob` admits one run.
actor CompanionPublishing {
    private let support: URL
    private let deviceID: String
    private var seen: [String: (hash: String, day: String)] = [:]
    private var lastShown: Set<String>?
    private var indexDue = true

    init(support: URL, deviceID: String) { self.support = support; self.deviceID = deviceID }

    func run(profile: CompanionProfile, target: any CompanionPublishingTarget, rows: [ShelfRow], now: Date,
             timeZone: TimeZone = .current) async throws -> CompanionPublishingReport {
        var report = CompanionPublishingReport()
        let today = CalendarDate.today(in: timeZone, now: now), at = Self.time(now)
        let onShelf = Dictionary(rows.map { ($0.folder.standardizedFileURL.path, $0) }, uniquingKeysWith: { a, _ in a })
        var shown: [(id: String, folder: URL)] = []
        for (folder, identity, match) in try CompanionBinderIdentities(support: support).all() {
            guard let sharing = try profile.binderSharing(identity), sharing.state == .shown else { continue }
            // A binder taken off the Shelf, or another folder in its place, is no longer shown: it could now hold anything.
            // A folder that is missing for now (offloaded) keeps its last view.
            guard onShelf[folder.path] != nil, match != .replaced else {
                try profile.hideBinder(identity); report.hidden += 1; continue
            }
            if match == .missing { report.skipped += 1; continue }
            shown.append((sharing.id, folder))
        }
        // §4.4: until every remaining phone's new keys are on the relay, nothing is published at the new epoch, so no
        // phone meets an index it cannot open.
        if try profile.rotationBlocksPublication() { report.held = true; return report }
        // After a rotation, each shown binder gets a view at its new key epoch, changed or not (§4.4 step 4).
        for id in try profile.bindersNeedingEpochView() { seen[id] = nil }
        let ids = Set(shown.map(\.id))
        if ids != lastShown { indexDue = true }
        for binder in shown {
            try Task.checkCancellation()
            // One binder that cannot be read now (offloaded, busy, needing attention, another Mac's) keeps its last view.
            do { if try snapshot(binder.id, binder.folder, profile: profile, today: today, at: at) { report.snapshots += 1 } }
            catch { report.skipped += 1 }
            switch try await target.uploadView(binderID: binder.id) {
            case .uploaded: report.uploads += 1; indexDue = true
            case .superseded: seen[binder.id] = nil
            case .waiting, .idle: break
            }
        }
        let pending = try profile.pendingIndex() != nil
        if indexDue || pending {
            switch try await target.uploadIndex(generatedAt: at) {
            // A resumed index was built before this run's uploads, so another follows it at the next run.
            case .uploaded: report.indexes += 1; indexDue = pending; lastShown = pending ? nil : ids
            case .superseded, .waiting, .idle: break
            }
        }
        report.deletions = try await target.cleanRemovedBinders(limit: 50)
        seen = seen.filter { ids.contains($0.key) }
        return report
    }

    /// Under the binder's write lock: a new snapshot only when the catalog or the day changed since the last one.
    private func snapshot(_ id: String, _ folder: URL, profile: CompanionProfile, today: CalendarDate, at: String) throws -> Bool {
        guard Commands.ownerDevice(of: folder) == deviceID else { throw CompanionPublicationError.unavailable }
        return try TekaStore(folder: folder).withCompanionTransaction { transaction in
            let state = try transaction.currentState()
            if let last = seen[id], last.hash == state.hash, last.day == today.description { return false }
            let reading = CompanionViewReading.of(catalog: state.catalog, folder: folder, today: today, generatedAt: at)
            _ = try profile.prepareView(binderID: id, reading: reading)
            seen[id] = (state.hash, today.description)
            return true
        }
    }

    static func time(_ date: Date) -> String {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)).ISO8601Format()
    }
}
