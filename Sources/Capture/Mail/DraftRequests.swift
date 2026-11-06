import Foundation
import SpravaKit

/// Approved drafts waiting to be placed in the account's Drafts folder (integrations.md §5.2, D41), one private folder
/// each under `capture/draft-requests/<card id>/`: the message built at approval (`message.eml`) and its state
/// (`request.json`). A request is written before its card is approved and marked ready after, so an approved card
/// always has one; one never marked ready belongs to a card that was not approved, and is removed.
public struct DraftRequests: Sendable {
    public enum State: String, Sendable { case approving, ready, failed }
    public enum Refused: Error, Equatable { case invalidID, missing }
    /// The largest message kept, as encoded: what the draft worker places at most.
    static let messageLimit = 32 * 1024 * 1024

    public struct Request: Sendable, Equatable {
        public let id: String
        /// The binder's folder, as a path.
        public let binder: String
        public var state: State
        /// Why it could not be placed, in fixed words, when `failed`.
        public var failure: String?
        /// When it was written: one still `approving` long after belongs to an approval that did not finish.
        public let created: Date
        /// The account it was approved for (`account(of:)`): it goes there or nowhere.
        public let account: String
    }

    /// An account as a draft's destination: its server and user, never its password.
    public static func account(of a: IMAPAccount) -> String { "\(a.user)@\(a.host.lowercased()):\(a.port)" }

    public let root: URL
    public init(support: URL) { root = support.appendingPathComponent("capture/draft-requests", isDirectory: true) }

    /// A card id is a UUID, so a folder name is never taken from anything else.
    static func valid(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    /// Writes the message for card `id` before it is approved.
    public func begin(id: String, binder: URL, account: String, message: Data, now: Date = Date()) throws {
        guard Self.valid(id) else { throw Refused.invalidID }
        try AtomicFile.makePrivateFolder(root)
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try AtomicFile.makePrivateFolder(folder)
        try AtomicFile.write(message, to: folder.appendingPathComponent("message.eml"))
        try write(Request(id: id, binder: binder.standardizedFileURL.path, state: .approving, failure: nil, created: now, account: account))
    }

    /// The card was approved: the request may be placed.
    public func ready(id: String) throws { try update(id) { $0.state = .ready; $0.failure = nil } }

    /// It cannot be placed until the person acts: `reason` is fixed words, never content.
    public func failed(id: String, reason: String) throws { try update(id) { $0.state = .failed; $0.failure = reason } }

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
        guard case .ok(let data) = SafeFile.read(root.appendingPathComponent(id).appendingPathComponent("request.json"), limit: 64 * 1024),
              let value = try? JSONParser.parse(data).value, value["id"]?.stringValue == id,
              let binder = value["binder"]?.stringValue, let state = value["state"]?.stringValue.flatMap(State.init(rawValue:)),
              let created = ISOTime.date(value["created"]?.stringValue), let account = value["account"]?.stringValue else { return nil }
        return Request(id: id, binder: binder, state: state, failure: value["failure"]?.stringValue, created: created, account: account)
    }

    func write(_ request: Request) throws {
        var o = JSONObject([(key: "id", value: .string(request.id)), (key: "binder", value: .string(request.binder)),
                            (key: "state", value: .string(request.state.rawValue)),
                            (key: "created", value: .string(ISOTime.string(request.created))), (key: "account", value: .string(request.account))])
        if let failure = request.failure { o.set("failure", .string(failure)) }
        try AtomicFile.write(Data(JSONWriter.compact(.object(o)).utf8), to: root.appendingPathComponent(request.id).appendingPathComponent("request.json"))
    }

    func update(_ id: String, _ change: (inout Request) -> Void) throws {
        guard Self.valid(id), var request = read(id) else { throw Refused.missing }
        change(&request)
        try write(request)
    }
}
