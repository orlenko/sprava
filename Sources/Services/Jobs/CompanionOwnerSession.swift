import Companion
import Foundation

public enum CompanionOwnerRuntimeStatus: Sendable, Equatable {
    case notConfigured
    case claim(CompanionOwnerClaimState)
}

/// Runtime owns one session per profile and shares its device locks with decisions, publication and removal.
/// Explicit paths/backends only. Status reads keyless metadata and remains available during network recovery.
/// The profile is reopened lazily so setup performed after startup is visible without restarting (§6).
public actor CompanionOwnerSession {
    public let deviceDecisionLocks = CompanionDeviceDecisionLocks()
    private let database: URL
    private let secrets: any CompanionCredentialStorage
    private let recover: @Sendable (CompanionProfile) async throws -> CompanionOwnerClaimState
    private let prepare: @Sendable (String, String, String?) async throws -> CompanionProfile
    /// Pairing steps for one opened profile; tests replace the relay-backed flow and delivery.
    nonisolated let pairing: @Sendable (CompanionProfile) throws -> CompanionPairingSteps
    /// One bounded removal/rotation step for an opened profile (§4.4); tests replace the relay.
    nonisolated let rotation: @Sendable (CompanionProfile) -> @Sendable () async throws -> CompanionRotationProgress
    /// Best-effort relay step of a reset (§4.4 removal path); tests replace the relay.
    private let refuse: @Sendable (CompanionProfile, @escaping @Sendable () -> Bool) async -> CompanionOwnerResetReport
    private var recovering = false
    /// While a reset runs, no job run, recovery or Phone action is admitted.
    private var resetting = false
    /// The job's runs in flight, so a reset can stop them before it forgets anything (`runWork`).
    private var works: [UUID: Task<Void, Error>] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// How long a reset waits for a cancelled run to end, a few seconds past one relay call's 30, and how long it keeps
    /// starting relay calls (each at most 30 seconds): at most 90 seconds, inside the app's 100 for a Phone action.
    let resetDeadlines: (work: Duration, relay: Duration)
    /// Counts the resets this session made, so a runtime cache made for an earlier setup of the same relay is made again.
    public private(set) var generation = 0
    static let relayRotation: @Sendable (CompanionProfile) -> @Sendable () async throws -> CompanionRotationProgress = { profile in
        let worker = CompanionOwnerRotation(profile: profile)
        return { try await worker.step() }
    }

    public init(database: URL, secrets: any CompanionCredentialStorage) {
        self.database = database; self.secrets = secrets
        recover = { try await CompanionOwnerConnection(profile: $0).recoverClaim() }
        prepare = { origin, code, web in
            try await CompanionOwnerSetup.prepare(database: database, origin: origin, setupCode: code,
                                                  webOrigin: web, secrets: secrets)
        }
        pairing = CompanionPairingSteps.relay
        rotation = Self.relayRotation
        refuse = { await CompanionOwnerReset.refusePhones($0, admit: $1) }
        resetDeadlines = (.seconds(35), .seconds(25))
    }
    init(database: URL, secrets: any CompanionCredentialStorage,
         recover: @escaping @Sendable (CompanionProfile) async throws -> CompanionOwnerClaimState,
         prepare: (@Sendable (String, String, String?) async throws -> CompanionProfile)? = nil,
         pairing: (@Sendable (CompanionProfile) throws -> CompanionPairingSteps)? = nil,
         rotation: (@Sendable (CompanionProfile) -> @Sendable () async throws -> CompanionRotationProgress)? = nil,
         refuse: (@Sendable (CompanionProfile, @escaping @Sendable () -> Bool) async -> CompanionOwnerResetReport)? = nil,
         resetDeadlines: (work: Duration, relay: Duration) = (.seconds(35), .seconds(25))) {
        self.database = database; self.secrets = secrets; self.recover = recover
        self.prepare = prepare ?? { origin, code, web in
            try await CompanionOwnerSetup.prepare(database: database, origin: origin, setupCode: code,
                                                  webOrigin: web, secrets: secrets)
        }
        self.pairing = pairing ?? CompanionPairingSteps.relay
        self.rotation = rotation ?? Self.relayRotation
        self.refuse = refuse ?? { await CompanionOwnerReset.refusePhones($0, admit: $1) }
        self.resetDeadlines = resetDeadlines
    }
    /// Setup and background claim recovery share one admission slot, while keyless status stays readable.
    /// Preparation stores the immutable identity; a separate claim action performs owner admission (§6).
    public func configure(origin: String, setupCode: String, webOrigin: String?) async throws -> CompanionOwnerRuntimeStatus {
        guard !recovering, !resetting else { throw CompanionOwnerConnectionError.busy }
        try Task.checkCancellation()
        recovering = true; defer { recovering = false }
        let profile = try await prepare(origin, setupCode, webOrigin)
        try Task.checkCancellation()
        return .claim(try profile.ownerClaimState())
    }
    /// Other owner actions share setup/recovery admission, without blocking keyless status while awaiting I/O.
    /// The callback owns domain admission (including whether a refused claim permits local recovery),
    /// bounded relay calls and any per-device decision lock. The profile is reopened for each action (§6).
    func withConfiguredProfile<Result: Sendable>(
        _ action: @Sendable (CompanionProfile) async throws -> Result
    ) async throws -> Result? {
        guard !recovering, !resetting else { throw CompanionOwnerConnectionError.busy }
        try Task.checkCancellation()
        guard let profile = try CompanionProfile.openConfigured(database: database, secrets: secrets) else { return nil }
        recovering = true; defer { recovering = false }
        let result = try await action(profile)
        try Task.checkCancellation()
        return result
    }
    /// Keyless and local, like status: labels and confirmation states without network or admission (§5.2).
    /// The reader must not load a key or call the relay.
    func readProfile<Result: Sendable>(_ reader: (CompanionProfile) throws -> Result) throws -> Result? {
        guard let profile = try CompanionProfile.openConfigured(database: database, secrets: secrets) else { return nil }
        return try reader(profile)
    }
    public func snapshot() throws -> CompanionOwnerRuntimeStatus {
        guard let profile = try CompanionProfile.openConfigured(database: database, secrets: secrets) else { return .notConfigured }
        return .claim(try profile.ownerClaimState())
    }
    /// One bounded owner-connection attempt, with its durable claim/admission behavior owned by Companion.
    /// Disabled sessions do no network/key work. Errors propagate and always release the recovery slot.
    public func recoverClaim() async throws -> CompanionOwnerRuntimeStatus {
        guard !recovering, !resetting else { throw CompanionOwnerConnectionError.busy }
        try Task.checkCancellation()
        guard let profile = try CompanionProfile.openConfigured(database: database, secrets: secrets) else { return .notConfigured }
        recovering = true; defer { recovering = false }
        return .claim(try await recover(profile))
    }

    /// The companion job's work for one run, admitted unless a reset is running, and kept so a reset can cancel it and
    /// wait for it to end. A run a reset cancelled ends as a cancellation, not a failure.
    func runWork(_ body: @escaping @Sendable () async throws -> Void) async throws {
        guard !resetting else { throw CompanionOwnerConnectionError.busy }
        let id = UUID(), task = Task { try await body() }
        works[id] = task
        defer { workEnded(id) }
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { throw task.isCancelled ? CancellationError() : error }
    }
    private func workEnded(_ id: UUID) {
        works[id] = nil
        guard works.isEmpty else { return }
        for waiter in idleWaiters.values { waiter.resume(returning: true) }
        idleWaiters = [:]
    }
    /// True once no run is in flight; false at the deadline, with the run still going.
    private func waitForIdle(_ deadline: Duration) async -> Bool {
        if works.isEmpty { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            idleWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: deadline)
                await self?.expire(id)
            }
        }
    }
    private func expire(_ id: UUID) { idleWaiters.removeValue(forKey: id)?.resume(returning: false) }

    /// Reset of phone access (companion.md §13). The job's run in flight is cancelled and awaited first; one that does
    /// not end by the deadline makes the reset answer busy with nothing changed, since its relay client may still hold
    /// the owner token in memory. Then, best effort, the relay is asked to delete each phone; then this Mac forgets
    /// every credential of the relay and sets its companion folder aside (`CompanionOwnerReset`). Nil when nothing was
    /// set up. After it, `configure` takes any relay.
    public func reset(now: Date = Date()) async throws -> CompanionOwnerResetReport? {
        guard !recovering, !resetting else { throw CompanionOwnerConnectionError.busy }
        try Task.checkCancellation()
        recovering = true; resetting = true; defer { recovering = false; resetting = false }
        for task in works.values { task.cancel() }
        guard await waitForIdle(resetDeadlines.work) else { throw CompanionOwnerConnectionError.busy }
        var report = CompanionOwnerResetReport()
        // Once begun, the reset is finished even if its caller goes away: stopping halfway helps no one.
        if let profile = try CompanionProfile.openConfigured(database: database, secrets: secrets) {
            let end = ContinuousClock.now + resetDeadlines.relay
            report = await refuse(profile, { ContinuousClock.now < end })
        }
        guard let shown = try CompanionOwnerReset.forget(database: database, secrets: secrets, now: now) else { return nil }
        report.bindersTurnedOff = shown
        generation += 1
        return report
    }
}
