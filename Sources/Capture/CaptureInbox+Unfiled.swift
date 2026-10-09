import BinderFormat
import BinderStore
import CryptoKit
import Foundation
import Shelf
import SpravaKit

// Unfiled cards: written with their digests, listed, filed into a binder by the person, or discarded.
extension CaptureInbox {
    package func writeUnfiled(_ raw: JSONObject) throws {
        guard let id = raw["id"]?.stringValue, let file = unfiledFile(id) else { throw Commands.Failure(message: "a card without a valid id") }
        try AtomicFile.makePrivateFolder(unfiledDir)
        let bytes = Data(JSONWriter.pretty(.object(raw)).utf8)
        let digest = Self.digest(bytes)
        // The digest is recorded first: a card whose file was written but not recorded would never be shown. A card
        // rewritten in place keeps the digest of the file still there beside the new one until the new file is
        // down, so a rewrite that fails, or a crash in between, never hides the card; the next rewrite tries again.
        var digests = try unfiledDigests()
        var both: String?
        if case .ok(let data) = SafeFile.read(file), case let current = Self.digest(data), current != digest,
           Self.accepted(digests[id]).contains(current) {
            both = digest + " " + current
        }
        digests[id] = both ?? digest
        try saveUnfiledDigests(digests)
        try AtomicFile.write(bytes, to: file)
        if both != nil {
            digests[id] = digest
            try? saveUnfiledDigests(digests)   // a pair left behind still names the file there
        }
    }

    /// The digests an entry of the digest list accepts: one, or two while a card is rewritten.
    static func accepted(_ entry: String?) -> [String] { entry?.split(separator: " ").map(String.init) ?? [] }

    /// Card id -> digest of the file the inbox wrote. Throws when the list exists but cannot be read, so it is
    /// never saved over with one entry.
    package func unfiledDigests() throws -> [String: String] {
        try StateFile.read([String: String].self, from: unfiledDigestsURL) ?? [:]
    }

    package func saveUnfiledDigests(_ digests: [String: String]) throws {
        try AtomicFile.makePrivateFolder(dir)
        try AtomicFile.write(try JSONEncoder().encode(digests), to: unfiledDigestsURL)
    }

    package static func digest(_ data: Data) -> String { "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Unfiled cards waiting for the person to pick a binder. A card whose file changed since the inbox wrote it is
    /// left out, and so is one whose name is not `<id>.json` for the id inside it; none is shown while the digest
    /// list cannot be read (the sweep reports that).
    public func unfiled() -> [Proposal] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: unfiledDir.path),
              let digests = try? unfiledDigests() else { return [] }
        return names.filter { $0.hasSuffix(".json") && ProposalStore.isValidID(String($0.dropLast(5))) }.sorted().compactMap { name in
            let id = String(name.dropLast(5))
            guard case .ok(let data) = SafeFile.read(unfiledDir.appendingPathComponent(name)),
                  Self.accepted(digests[id]).contains(Self.digest(data)),
                  case .object(let o)? = try? JSONParser.parse(data).value, o["id"]?.stringValue == id else { return nil }
            return Proposal(raw: o)
        }
    }

    /// Moves an unfiled card into the binder the person picked, as a proposal there under the same id. The binder's
    /// copy is saved and trusted first; only then does the Inbox let go of the card, its digest and then its file.
    /// A crash in between leaves the card in both places, never in neither, and the next sweep drops the Inbox copy
    /// of a card already trusted in a binder (`dropFiled`). An Inbox card can only be filed, never approved, so the
    /// two copies are never both approvable.
    public func file(_ proposalID: String, into folder: URL, commands: Commands) throws {
        guard ProposalStore.isValidID(proposalID), var raw = unfiled().first(where: { $0.id == proposalID })?.raw else {
            throw Commands.Failure(message: "this card is gone or changed since Sprava wrote it")
        }
        let teka = Teka.read(folder)
        guard teka.isAdopted else { throw Commands.Failure(message: "this binder is not adopted yet") }
        guard Owner.device(of: folder) == commands.deviceID else { throw Commands.Failure(message: "this binder is read-only here") }
        // Filed before a crash: only the Inbox's copy is left to remove.
        if !commands.isTrusted(proposalID, in: folder) {
            // Filed into another binder before a crash: never a second approvable copy.
            if (try? commands.loadDigests())?.keys.contains(where: { $0.hasSuffix("#" + proposalID) }) == true {
                throw Commands.Failure(message: "this card was already filed into another binder; it leaves the Inbox shortly")
            }
            for key in ["binder", "source_retracted", "source_corrected"] { raw.remove(key) }
            // A raise to private recorded in the cursor holds for the card even when its rewrite in the Inbox failed
            // (capture-event-v0 §3.3); a cursor that cannot be read files nothing.
            let privates = Set(try readState().privates ?? [])
            let events = raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if raw["provenance"]?["private"] != .bool(true), events.contains(where: privates.contains) {
                raw = Self.privateCopy(Proposal(raw: raw), catalog: teka.catalog).raw
            }
            try ProposalStore.save(Proposal(raw: raw), in: folder)
            do { try commands.trustProposals([proposalID], in: folder) } catch {
                // A copy saved but not trusted cannot be approved; it is taken back, and the Inbox keeps the card.
                if let (p, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == proposalID }) {
                    try? TekaStore(folder: folder).reject(p, reason: "it could not be moved from the Inbox")
                }
                throw error
            }
        }
        // The card is in the binder now; a leftover the Inbox could not let go of is dropped by the next sweep.
        try? letGo(proposalID)
        journal([("card", .string(proposalID)), ("stage", .str("filed_by_person"))])
    }

    /// The Inbox lets go of a card: its digest first, so the leftover file is never shown, then the file.
    func letGo(_ id: String) throws {
        var digests = try unfiledDigests()
        if digests.removeValue(forKey: id) != nil { try saveUnfiledDigests(digests) }
        if let file = unfiledFile(id) { try? FileManager.default.removeItem(at: file) }
    }

    /// Drops from the Inbox every card already filed: a trusted proposal with its id waits in a binder this Mac
    /// manages. That is what a filing cut short by a crash leaves behind (`file`).
    func dropFiled(binders: [ShelfRow], commands: Commands) {
        let waiting = Set(unfiled().map(\.id))
        guard !waiting.isEmpty else { return }
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            for (p, _) in ProposalStore.list(in: row.folder) where waiting.contains(p.id) && commands.isTrusted(p.id, in: row.folder) {
                guard (try? letGo(p.id)) != nil else { continue }
                journal([("card", .string(p.id)), ("stage", .str("filed_by_person_finished"))])
            }
        }
    }

    public func discard(_ proposalID: String) throws {
        guard let file = unfiledFile(proposalID) else { throw Commands.Failure(message: "bad card id") }
        try FileManager.default.removeItem(at: file)
        journal([("card", .string(proposalID)), ("stage", .str("discarded"))])
    }
}
