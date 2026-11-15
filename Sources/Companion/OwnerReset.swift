import Darwin
import Foundation
import SpravaKit

/// What a reset did, by count only: never an id, label or address.
public struct CompanionOwnerResetReport: Sendable, Equatable {
    /// Phones the relay confirmed deleting, so it refuses them at once.
    public var phonesRefused = 0
    /// Phones the relay was not asked about or did not confirm: it keeps taking them until it is deleted or started over.
    public var phonesNotReached = 0
    /// Binders that were shown on the phone; "Show on my phone" is off for each after the reset.
    public var bindersTurnedOff = 0
    public init() {}
}

public enum CompanionOwnerResetError: Error, Sendable, Equatable {
    /// A phone's decision is recorded but not finished; nothing was changed (§9.4).
    case decisionPending
}

protocol OwnerResetTransport: Sendable {
    func deleteDevice(deviceID: String, downloadLimit: Int) async throws -> CompanionRelayReply<Data>
}
extension CompanionOwnerRelay: OwnerResetTransport {}

/// Reset of phone access (companion.md §13): forget this Mac's relay setup so it can connect to another relay or a
/// relay started over. Paired phones lose access and must be paired again. Each step is safe to interrupt and repeat:
/// until the last one the old state stays where it was and a second reset finishes the work.
public enum CompanionOwnerReset {
    /// Relay calls the best-effort step makes at most, each bounded to 30 seconds.
    public static let relayCalls = 20

    /// Best effort, never required: while the relay is claimed, ask it to delete each phone this Mac knows (companion-v0
    /// §7.4, `DELETE /v0/devices/{D}`), so it refuses them right away. Stops at the first failure: a relay that is down
    /// or refuses this Mac is not asked again. `admit` is checked before each call, so a caller's deadline holds.
    public static func refusePhones(_ profile: CompanionProfile, admit: @Sendable () -> Bool = { true }) async -> CompanionOwnerResetReport {
        let transport: (any OwnerResetTransport)? = {
            guard let owner = try? CompanionOwnerVault(backend: profile.secrets).load(profile.relay) else { return nil }
            return try? CompanionOwnerRelay(relay: profile.relay, token: owner.ownerToken)
        }()
        return await refusePhones(profile, transport: transport, admit: admit)
    }
    static func refusePhones(_ profile: CompanionProfile, transport: (any OwnerResetTransport)?,
                             admit: @Sendable () -> Bool) async -> CompanionOwnerResetReport {
        var report = CompanionOwnerResetReport()
        guard let devices = try? profile.devicesTheRelayMayKnow() else { return report }
        let state = try? profile.ownerClaimState()
        // A relay started over already has none of this Mac's phones.
        report.phonesNotReached = state == .instanceChanged ? 0 : devices.count
        guard let transport, state == .claimed else { return report }
        for device in devices.prefix(relayCalls) {
            guard admit(), !Task.isCancelled,
                  let reply = try? await transport.deleteDevice(deviceID: device, downloadLimit: 4096), reply.status == 204 else { break }
            report.phonesRefused += 1; report.phonesNotReached -= 1
        }
        return report
    }

    /// The local reset. First every credential of the relay identity is forgotten, the owner token and signing key
    /// first, so the old setup can make no further relay call; then the whole `companion` folder (the state with its
    /// WAL, and development credential files) is renamed aside with a timestamp, never deleted. A process still
    /// holding the old state writes only into the folder set aside. Nil when nothing was set up. A phone decision begun
    /// and not finished refuses the reset before anything changes; the caller finishes it first.
    public static func forget(database: URL, secrets: any CompanionCredentialStorage,
                              now: Date = Date()) throws -> Int? {
        let folder = database.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let shown: Int
        do {
            guard let profile = try CompanionProfile.openConfigured(database: database, secrets: secrets) else { return nil }
            guard try profile.devicesWithPendingDecisions().isEmpty else { throw CompanionOwnerResetError.decisionPending }
            let plan = try profile.resetPlan()
            for account in plan.accounts { try secrets.remove(account: account) }
            shown = plan.shownBinders
        }
        try moveAside(folder, now: now)
        return shown
    }

    /// `companion` becomes `companion-reset-<UTC time>` beside it (a numbered name when that exists). The rename never
    /// replaces anything; a crash before it leaves the old state, whose credentials a second reset forgets again.
    static func moveAside(_ folder: URL, now: Date) throws {
        let parent = folder.deletingLastPathComponent()
        let stamp = now.ISO8601Format().replacingOccurrences(of: ":", with: "") // 2026-11-15T101530Z
        for n in 1...100 {
            let name = folder.lastPathComponent + "-reset-" + stamp + (n == 1 ? "" : "-\(n)")
            if renamex_np(folder.path, parent.appendingPathComponent(name).path, UInt32(RENAME_EXCL)) == 0 { return }
            guard errno == EEXIST else { throw CompanionCredentialError.unavailable }
        }
        throw CompanionCredentialError.unavailable
    }
}

extension CompanionProfile {
    /// Every credential name this profile may have stored, the owner's first, and the binders shown now (keyless).
    /// Account and binder keys live at the current epoch, the next one (staged by a rotation whose commit failed)
    /// and every earlier epoch still awaiting discard; device and pairing keys under each device ever reserved.
    func resetPlan() throws -> (accounts: [String], shownBinders: Int) {
        try store.read { t in
            guard let e = try epoch(t) else { throw CompanionCredentialError.unavailable }
            let discard = try t.rows("SELECT epoch FROM discard_epochs ORDER BY epoch").map { row in
                guard row.count == 1, let n = row[0].integer, n >= 1 else { throw CompanionCredentialError.invalid }
                return n
            }
            let epochs = Set(discard + [e, e + 1]).sorted()
            // A binder switched off keeps the key of its own epoch until its cleanup, even past that epoch's discard.
            let binders = try t.rows("SELECT binder, key_epoch FROM phone_binders ORDER BY binder").map { row in
                guard row.count == 2, let id = row[0].text, CompanionWire.isID(id), let own = row[1].integer, own >= 1 else {
                    throw CompanionCredentialError.invalid
                }
                return (id, own)
            }
            let devices = try t.rows("SELECT device FROM devices ORDER BY device").map { row in
                guard row.count == 1, let id = row[0].text, CompanionWire.isID(id) else { throw CompanionCredentialError.invalid }
                return id
            }
            var accounts = [relay.account] + epochs.map(keyAccount)
            for (id, own) in binders { accounts += Set(epochs + [own]).sorted().map { binderKeyAccount(id, epoch: $0) } }
            for id in devices { accounts += [deviceAccount(id), pairingAccount(id), createdAccount(id)] }
            let shown = try t.rows("SELECT COUNT(*) FROM phone_binders WHERE state = 'shown'").first?.first?.integer ?? 0
            return (accounts, Int(shown))
        }
    }

    /// Phones with a decision recorded but not finished (companion-v0 §9.4): a reset waits until each is finished, so a
    /// phone's note or Done that was begun is never lost with the state set aside. Keyless.
    public func devicesWithPendingDecisions() throws -> [String] {
        try store.read { t in
            try t.rows("SELECT device FROM request_decisions ORDER BY device").map { row in
                guard row.count == 1, let id = row[0].text, CompanionWire.isID(id) else { throw CompanionCredentialError.invalid }
                return id
            }
        }
    }

    /// Phones the relay may still take: every device reserved here but one whose relay deletion was confirmed or whose
    /// pairing was given up.
    func devicesTheRelayMayKnow() throws -> [String] {
        try store.read { t in
            try t.rows("SELECT d.device FROM devices d WHERE d.state IN ('pairing', 'active') OR (d.state = 'revoked' AND " +
                       "EXISTS (SELECT 1 FROM device_removals r WHERE r.device = d.device AND r.relay_delete = 1)) ORDER BY d.device").map { row in
                guard row.count == 1, let id = row[0].text, CompanionWire.isID(id) else { throw CompanionCredentialError.invalid }
                return id
            }
        }
    }
}
