import BinderStore
import Companion
import Foundation
import Shelf
import SpravaKit

/// "Show on my phone", one switch per binder, off by default (companion.md §2, principle 6; companion-v0 §8.4).
/// On reserves a new random phone id and binder key; off records the binder as removed, so no snapshot or upload of it
/// follows and the next index leaves it out. Turning it on again makes a new id and key; a request for the old id is
/// rejected (§9.5). Both run on the Phone queue, sharing the owner session's admission slot.
public struct CompanionBinderSwitch: Sendable {
    let support: URL
    let deviceID: String
    public init(support: URL, deviceID: String) { self.support = support; self.deviceID = deviceID }

    func handlers(session: CompanionOwnerSession) -> [String: CompanionPhoneActions.Handler] {
        let identities = CompanionBinderIdentities(support: support)
        return [
            "companion_binder_show": { request in
                let folder = try Self.folder(request, "companion_binder_show")
                try checkShowable(folder)
                return try await Self.perform {
                    try await session.withConfiguredProfile { profile in
                        // Another folder put where a shown binder was is switched off before this one is shown.
                        try profile.showBinder(try identities.identity(for: folder, retire: { try profile.hideBinder($0) })).state == .shown
                    }
                }
            },
            "companion_binder_hide": { request in
                let folder = try Self.folder(request, "companion_binder_hide")
                // An identity record that cannot be read fails visibly; only a binder never shown answers "off" at once.
                let identity: CompanionLocalBinderIdentity?
                do { identity = try identities.existing(for: folder) } catch { throw CompanionPhoneActionError.unavailable }
                guard let identity else { return Self.answer(shown: false) }
                return try await Self.perform {
                    try await session.withConfiguredProfile { profile in
                        try profile.hideBinder(identity)
                        return false
                    }
                }
            },
        ]
    }

    /// Only a binder this Mac writes can take a phone's actions: adopted, on the Shelf and owned by this Mac.
    func checkShowable(_ folder: URL) throws {
        let onShelf = ShelfStore(supportDirectory: support).rows().contains { $0.folder.standardizedFileURL.path == folder.path }
        let adopted = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava/ops.ndjson").path)
        guard onShelf, adopted, Commands.ownerDevice(of: folder) == deviceID else { throw CompanionPhoneActionError.notShowable }
    }

    static func folder(_ request: JSONObject, _ command: String) throws -> URL {
        guard request["command"] == .str(command), Set(request.entries.map(\.key)) == ["command", "binder"],
              let path = request["binder"]?.stringValue, path.hasPrefix("/") else { throw CompanionPhoneActionError.notShowable }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    static func answer(shown: Bool) -> JSONObject { JSONObject([(key: "shown", value: .bool(shown))]) }

    /// Fixed sentences only: errors may carry paths or relay details.
    private static func perform(_ action: () async throws -> Bool?) async throws -> JSONObject {
        do {
            guard let shown = try await action() else { throw CompanionPhoneActionError.notSetUp }
            return answer(shown: shown)
        } catch let error as CompanionPhoneActionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch CompanionOwnerConnectionError.busy {
            throw CompanionPhoneActionError.busy
        } catch CompanionPublicationError.tooManyBinders {
            throw CompanionPhoneActionError.tooManyShown
        } catch CompanionPublicationError.unavailable {
            throw CompanionPhoneActionError.notSetUp
        } catch {
            throw CompanionPhoneActionError.unavailable
        }
    }
}

extension Commands {
    /// Whether a binder is shown on the phone, and whether it could be: metadata only, no credential reads (§6).
    func companionBinderStatus(_ r: JSONObject) throws -> JSONObject {
        let folder = try folder(r)
        do {
            let database = support.appendingPathComponent("companion/state.sqlite")
            guard let profile = try CompanionProfile.openConfigured(database: database, secrets: CompanionMetadataCredentials()) else {
                return JSONObject([(key: "shown", value: .bool(false)), (key: "available", value: .bool(false))])
            }
            let available = try profile.ownerClaimState() == .claimed
            let identity = try CompanionBinderIdentities(support: support).existing(for: folder)
            let shown = try identity.flatMap { try profile.binderSharing($0) }?.state == .shown
            return JSONObject([(key: "shown", value: .bool(shown)), (key: "available", value: .bool(available))])
        } catch {
            throw Failure(message: "Whether this binder is shown on the phone is unavailable.")
        }
    }
}
