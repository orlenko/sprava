import Foundation
import SpravaKit

/// Approved drafts waiting to be placed in the account's Drafts folder (integrations.md §5.2, D41), one private folder
/// each under `capture/draft-requests/<card id>/`: the message built at approval (`message.eml`) and its state
/// (`request.json`). A request is written before its card is approved and marked ready after, so an approved card
/// always has one; one never marked ready belongs to a card that was not approved, and is removed.
public struct DraftRequests: Sendable {
    public enum State: String, Sendable { case approving, ready, failed }
    public enum Refused: Error, Equatable { case invalidID, missing, exists, metadataTooLarge }
    /// The largest message kept, as encoded: what the draft worker places at most.
    static let metadataLimit = 64 * 1024
    static let messageLimit = 32 * 1024 * 1024

    public struct Request: Sendable, Equatable {
        public let id: String
        /// The binder's folder, as a path.
        public fileprivate(set) var binder: String
        /// Absent on requests created before physical folder ownership was recorded.
        public fileprivate(set) var binderInstance: String?
        /// Digest of the applied card as Sprava wrote it, independent of the binder's location.
        public fileprivate(set) var appliedDigest: String? = nil

        /// Only the physical directory that owned the approval may see or act on this request.
        public func belongs(to folder: URL) -> Bool {
            guard let binderInstance else { return false }
            return (try? BinderIMAPConnections.folderIdentity(folder.resolvingSymlinksInPath())) == binderInstance
        }

        public var state: State
        /// Why it could not be placed, in fixed words, when `failed`.
        public var failure: String?
        /// A short label for the binder page, from the approved card. Absent on older requests.
        public var subject: String?
        /// When it was written: one still `approving` long after belongs to an approval that did not finish.
        public let created: Date
        /// The account it was approved for (`account(of:)`): it goes there or nowhere.
        public let account: String
        /// Placements tried that ended in no known answer, and when the last was.
        public var attempts = 0
        public var tried: Date?
    }

    /// An account as a draft's destination: its server and user, never its password.
    public static func account(of a: IMAPAccount) -> String { "\(a.user)@\(a.host.lowercased()):\(a.port)" }

    public let root: URL
    public init(support: URL) { root = support.appendingPathComponent("capture/draft-requests", isDirectory: true) }

    /// A card id is a UUID, so a folder name is never taken from anything else.
    static func valid(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    /// Writes the message for card `id` before it is approved.
    public func begin(id: String, binder: URL, account: String, message: Data, subject: String? = nil, now: Date = Date()) throws {
        guard Self.valid(id) else { throw Refused.invalidID }
        let instance = try BinderIMAPConnections.folderIdentity(binder.resolvingSymlinksInPath())
        // Only a request still waiting for its approval is written again: one approved, placed or failed is the person's.
        if let existing = read(id), (existing.state != .approving || existing.binderInstance != instance) { throw Refused.exists }
        try AtomicFile.makePrivateFolder(root)
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try AtomicFile.makePrivateFolder(folder)
        try AtomicFile.write(message, to: folder.appendingPathComponent("message.eml"))
        try write(Request(id: id, binder: binder.standardizedFileURL.path, binderInstance: instance, state: .approving, failure: nil,
                          subject: subject.flatMap(Self.label), created: now, account: account))
    }

    private static func label(_ subject: String) -> String? {
        var output = "", used = 0
        for character in subject {
            let size = character.utf8.count
            guard used + size <= 320 else { break }
            if character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 0x200D
                || $0.properties.isBidiControl }) { continue }
            output.append(character)
            used += size
        }
        return output.isEmpty ? nil : output
    }

    /// The card was approved: the request may be placed.
    public func ready(id: String, appliedDigest: String? = nil) throws {
        try update(id) {
            if let appliedDigest { $0.appliedDigest = appliedDigest }
            $0.state = .ready; $0.failure = nil; $0.attempts = 0; $0.tried = nil
        }
    }

    /// After the person reconnects a verified copy. A separate retry places the original message.
    public func reconnect(_ expected: Request, to folder: URL) throws {
        guard var request = read(expected.id), request == expected else { throw Refused.missing }
        request.binderInstance = try BinderIMAPConnections.folderIdentity(folder.resolvingSymlinksInPath())
        request.binder = folder.standardizedFileURL.path
        request.state = .failed
        request.failure = "Reconnected to this binder. Choose Try again to place the approved draft."
        try write(request)
    }

    /// It cannot be placed until the person acts: `reason` is fixed words, never content.
    public func failed(id: String, reason: String) throws { try update(id) { $0.state = .failed; $0.failure = reason } }

    /// A placement ended with no known answer: counted, so it is spaced out and, past a few, told to the person.
    public func attempted(id: String, at: Date) throws { try update(id) { $0.attempts += 1; $0.tried = at } }

    /// Removes it only when it is still the one written at `created`: an approval writing it again is never undone.
    public func remove(id: String, ifCreated created: Date) throws {
        guard let current = read(id), current.created == created else { return }
        try remove(id: id)
    }

    /// Placed, discarded, or its card was never approved.
    public func remove(id: String) throws {
        guard Self.valid(id) else { return }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    public func message(id: String) throws -> Data {
        guard Self.valid(id), case .ok(let data) = SafeFile.read(root.appendingPathComponent(id).appendingPathComponent("message.eml"),
                                                                 limit: Self.messageLimit) else {
            throw Refused.missing
        }
        return data
    }

    /// Every request that can be read; one that cannot is left alone, never placed.
    public func all() -> [Request] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter(Self.valid).sorted().compactMap(read)
    }

    func read(_ id: String) -> Request? {
        guard case .ok(let data) = SafeFile.read(root.appendingPathComponent(id).appendingPathComponent("request.json"), limit: Self.metadataLimit),
              let value = try? JSONParser.parse(data).value, value["id"]?.stringValue == id,
              let binder = value["binder"]?.stringValue, let state = value["state"]?.stringValue.flatMap(State.init(rawValue:)),
              let created = ISOTime.date(value["created"]?.stringValue), let account = value["account"]?.stringValue else { return nil }
        var request = Request(id: id, binder: binder, binderInstance: value["binder_instance"]?.stringValue, state: state, failure: value["failure"]?.stringValue,
                              subject: value["subject"]?.stringValue.flatMap(Self.label), created: created, account: account)
        request.appliedDigest = value["applied_digest"]?.stringValue
        request.attempts = value["attempts"]?.numberValue?.safeInteger.map { Int(max(0, min($0, 1000))) } ?? 0
        request.tried = ISOTime.date(value["tried"]?.stringValue)
        return request
    }

    func write(_ request: Request) throws {
        var o = JSONObject([(key: "id", value: .string(request.id)), (key: "binder", value: .string(request.binder)),
                            (key: "state", value: .string(request.state.rawValue)),
                            (key: "created", value: .string(ISOTime.string(request.created))), (key: "account", value: .string(request.account))])
        if let digest = request.appliedDigest { o.set("applied_digest", .str(digest)) }
        if let instance = request.binderInstance { o.set("binder_instance", .str(instance)) }
        if let subject = request.subject { o.set("subject", .string(subject)) }
        if let failure = request.failure { o.set("failure", .string(failure)) }
        if request.attempts > 0 { o.set("attempts", .int(request.attempts)) }
        if let tried = request.tried { o.set("tried", .string(ISOTime.string(tried))) }
        let metadata = Data(JSONWriter.compact(.object(o)).utf8)
        guard metadata.count <= Self.metadataLimit else { throw Refused.metadataTooLarge }
        try AtomicFile.write(metadata, to: root.appendingPathComponent(request.id).appendingPathComponent("request.json"))
    }

    func update(_ id: String, _ change: (inout Request) -> Void) throws {
        guard Self.valid(id), var request = read(id) else { throw Refused.missing }
        change(&request)
        try write(request)
    }
}
