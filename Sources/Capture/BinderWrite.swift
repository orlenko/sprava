import BinderFormat
import BinderStore
import Foundation
import SpravaKit

/// The one way the capture layer writes into a binder: saving a card, rejecting (withdrawing) one, rewriting one
/// Sprava wrote, or taking back one it saved but could not trust. Every write first reads the binder again, right
/// then: it must be adopted, its writes must not be blocked, and this Mac must own it (mvp.md feature 1). A binder
/// that became another Mac's, or blocked, since the work was planned is never written; the write throws, and the
/// work that needed it stays owed.
enum BinderWrite {
    struct NotWritable: Error, CustomStringConvertible {
        let path: String
        var description: String { "the binder can no longer be written from this Mac" }
    }

    /// Throws `NotWritable` unless this Mac may write into `folder` now.
    static func check(_ folder: URL, deviceID: String) throws {
        let teka = Teka.read(folder)
        guard teka.isAdopted, !teka.writesBlocked, Owner.device(of: folder) == deviceID else { throw NotWritable(path: folder.path) }
    }

    /// Whether this Mac may write into `folder` now.
    static func allowed(_ folder: URL, deviceID: String) -> Bool { (try? check(folder, deviceID: deviceID)) != nil }

    @discardableResult
    static func save(_ card: Proposal, in folder: URL, deviceID: String) throws -> String {
        try check(folder, deviceID: deviceID)
        return try ProposalStore.save(card, in: folder)
    }

    static func reject(_ card: Proposal, in folder: URL, reason: String?, deviceID: String, now: Date) throws {
        try check(folder, deviceID: deviceID)
        try TekaStore(folder: folder).reject(card, reason: reason, now: now)
    }

    @discardableResult
    static func rewriteTrusted(_ id: String, in folder: URL, commands: Commands, transform: (Proposal) throws -> Proposal) throws -> Proposal {
        try check(folder, deviceID: commands.deviceID)
        return try commands.rewriteTrusted(id, in: folder, transform: transform)
    }

    /// Takes back a card Sprava saved but whose digest it could not keep (it could never be approved): its file is
    /// removed, or, when that fails, it is rejected.
    static func takeBackUntrusted(_ card: Proposal, in folder: URL, deviceID: String, now: Date) {
        guard allowed(folder, deviceID: deviceID) else { return }
        let written = ProposalStore.dir(folder).appendingPathComponent("\(card.id).json")
        guard FileManager.default.fileExists(atPath: written.path), (try? FileManager.default.removeItem(at: written)) == nil else { return }
        try? TekaStore(folder: folder).reject(card, reason: "its digest could not be kept", now: now)
    }
}
