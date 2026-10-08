import BinderStore
import Extract
import Foundation
import SpravaKit

/// Sprava's own store of intake readings (§4.1 step 2), one file per reading in `capture/readings/`: the text,
/// the binder and card it belongs to, the model's reading once done, and whether a careful reading is wanted
/// (§4.4). The text never goes into a binder or a log.
public struct IntakeReadings: Sendable {
    public let support: URL

    public init(support: URL) { self.support = support }

    package var dir: URL { support.appendingPathComponent("capture/readings", isDirectory: true) }

    public struct Entry: Sendable {
        public var id: String
        public var binder: String           // the binder folder's path
        public var name: String             // relative to intake/
        public var sha256: String
        public var card: String             // the filing card this reading belongs to
        public var state: String            // pending, attempt, read, kept, gone
        public var attempts: Int
        public var reading: IntakeReading
        public var createdAt: String
        /// Why a careful reading is recommended; empty when it is not.
        public var escalate: [String]
        public var escalation: String?      // waiting, answered
        public var answer: String?          // the brain's proposal id
        public var result: JSONObject?      // the model's reading: class, title, date, summary, reply_needed

        var json: JSONObject {
            var o = JSONObject([(key: "id", value: .string(id)), (key: "binder", value: .string(binder)), (key: "name", value: .string(name)),
                                (key: "sha256", value: .string(sha256)), (key: "card", value: .string(card)), (key: "state", value: .string(state)),
                                (key: "attempts", value: .int(attempts)), (key: "reading", value: .object(reading.json)),
                                (key: "created_at", value: .string(createdAt))])
            if !escalate.isEmpty { o.set("escalate", .array(escalate.map(JSONValue.string))) }
            if let escalation { o.set("escalation", .string(escalation)) }
            if let answer { o.set("answer", .string(answer)) }
            if let result { o.set("result", .object(result)) }
            return o
        }

        package init(id: String, binder: String, name: String, sha256: String, card: String, reading: IntakeReading, now: Date) {
            self.id = id; self.binder = binder; self.name = name; self.sha256 = sha256; self.card = card
            self.state = "pending"; self.attempts = 0; self.reading = reading; self.createdAt = ISOTime.string(now)
            self.escalate = []
        }

        init?(json o: JSONValue) {
            guard let id = o["id"]?.stringValue, let binder = o["binder"]?.stringValue, let name = o["name"]?.stringValue,
                  let sha = o["sha256"]?.stringValue, let card = o["card"]?.stringValue, let r = o["reading"], let reading = IntakeReading(json: r)
            else { return nil }
            self.id = id; self.binder = binder; self.name = name; self.sha256 = sha; self.card = card; self.reading = reading
            state = o["state"]?.stringValue ?? "pending"
            attempts = Int(o["attempts"]?.numberValue?.safeInteger ?? 0)
            createdAt = o["created_at"]?.stringValue ?? ""
            escalate = o["escalate"]?.arrayValue?.compactMap(\.stringValue) ?? []
            escalation = o["escalation"]?.stringValue
            answer = o["answer"]?.stringValue
            result = o["result"]?.objectValue
        }
    }

    package func url(_ id: String) -> URL { dir.appendingPathComponent(id + ".json") }

    /// Throws when the reading cannot be written, so a caller never counts a reading as kept that is not.
    public func save(_ e: Entry) throws {
        try AtomicFile.makePrivateFolder(dir)
        try AtomicFile.write(Data(JSONWriter.pretty(.object(e.json)).utf8), to: url(e.id))
    }

    public func load(_ id: String) -> Entry? {
        guard id.wholeMatch(of: /[A-Za-z0-9-]{1,80}/) != nil, let data = try? Data(contentsOf: url(id)),
              let v = try? JSONParser.parse(data).value else { return nil }
        return Entry(json: v)
    }

    public func all() -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { load(String($0.dropLast(5))) }
    }

    public func forCard(_ card: String) -> Entry? { all().first { $0.card == card } }

    /// Drops readings that ended more than 60 days ago; a careful reading still waiting is kept.
    public func prune(now: Date) {
        for e in all() where ["read", "kept", "gone"].contains(e.state) && e.escalation != "waiting" {
            if let t = Timestamp.parse(e.createdAt), now.timeIntervalSince(t) > 60 * 86_400 { try? FileManager.default.removeItem(at: url(e.id)) }
        }
    }

    /// The careful readings a connected brain may pick up (§4.4): waiting, in binders it may see (all when nil),
    /// and whose card the person has not rejected.
    public func escalations(in folders: Set<String>? = nil) -> [Entry] {
        var states: [String: [String: String]] = [:]
        return all().filter { e in
            guard e.escalation == "waiting", folders?.contains(e.binder) ?? true else { return false }
            if states[e.binder] == nil { states[e.binder] = Self.cardStates(e.binder) }
            return Self.cardStands(states[e.binder]?[e.card])
        }
    }

    /// One careful reading a brain names by id, under the same rules as `escalations`: waiting, in `binder`, and
    /// its card not rejected. Every lookup by id goes through here, so a remembered id opens nothing more.
    public func escalation(_ id: String, in binder: String) -> Entry? {
        guard let e = load(id), e.binder == binder, e.escalation == "waiting",
              Self.cardStands(Self.cardStates(binder)[e.card]) else { return nil }
        return e
    }

    /// Proposal id -> state, for the cards in one binder.
    static func cardStates(_ binder: String) -> [String: String] {
        Dictionary(ProposalStore.list(in: URL(fileURLWithPath: binder, isDirectory: true)).map { ($0.0.id, $0.0.state) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// A reading is offered while its filing card waits or was approved; never once the person rejected it.
    static func cardStands(_ state: String?) -> Bool { ["proposed", "applied"].contains(state ?? "") }
}
