@testable import Brains
import Foundation
import SpravaKit
import Testing
@testable import Services

/// A running turn's question about a new site reaches the app through `chat_poll`, the person's tap goes back through
/// `chat_site_answer`, and the binder's settings list and remove its sites (conversation.md 18.3.1). Hosts are invented.
@Suite struct ClaudeSiteQuestionTests {
    typealias Fixture = ClaudeConversationTests.Fixture

    final class Outcome: @unchecked Sendable {
        private let lock = NSLock(); private var value: Bool?
        var result: Bool? { lock.withLock { value } }
        func set(_ allowed: Bool) { lock.withLock { value = allowed } }
        func wait() async throws -> Bool? {
            for _ in 0..<200 { if let result { return result }; try await Task.sleep(for: .milliseconds(10)) }
            return result
        }
    }

    /// A turn that holds until stopped, with its gate.
    func running(_ f: Fixture) async throws -> (id: UUID, turn: JSONValue, gate: AgentSiteGate) {
        try await f.connect(); f.engine.lock.withLock { f.engine.hold = true }
        let id = UUID(), started = try await f.send(id, "Read the invented invoicing service's API documentation.")
        for _ in 0..<200 where !f.engine.lock.withLock({ f.engine.running }) { try await Task.sleep(for: .milliseconds(10)) }
        let gate = try #require(f.engine.lock.withLock { f.engine.gate })
        return (id, try #require(started["turn_id"]), gate)
    }

    func poll(_ f: Fixture, _ id: UUID) async throws -> JSONObject { try await f.request("chat_poll", [("request_id", .str(id.uuidString))]) }

    @Test func aQuestionReachesTheAppAndAlwaysKeepsTheSiteForTheBinder() async throws {
        let f = try Fixture(), (id, turn, gate) = try await running(f)
        #expect(try await poll(f, id)["site_question"] == nil)
        let outcome = Outcome()
        gate.decide("docs.example-invoicing.test", .agent) { outcome.set($0) }
        let asked = try await poll(f, id)
        #expect(asked["site_question"]?["host"] == .str("docs.example-invoicing.test"))
        #expect(asked["site_question"]?["by_command"] == .bool(false))
        let question = try #require(asked["site_question"]?["id"])
        // A wrong turn or an unknown answer changes nothing.
        #expect(try await f.request("chat_site_answer", [("request_id", .str(id.uuidString)), ("question_id", question), ("answer", .str("forever"))])["answered"] == .bool(false))
        #expect(outcome.result == nil)
        #expect(try await f.request("chat_site_answer", [("request_id", .str(id.uuidString)), ("question_id", question), ("answer", .str("always"))])["answered"] == .bool(true))
        #expect(try await outcome.wait() == true)
        #expect(try await poll(f, id)["site_question"] == nil)
        let listed = try await f.request("chat_sites")["sites"]?.arrayValue
        #expect(listed == [.obj([("host", .str("docs.example-invoicing.test")), ("commands", .bool(false)), ("added", try #require(listed?.first?["added"]))])])
        #expect(try await f.request("chat_site_remove", [("host", .str("docs.example-invoicing.test"))])["sites"] == .array([]))
        _ = try await f.request("chat_stop", [("request_id", .str(id.uuidString)), ("turn_id", turn)])
    }

    @Test func stopRefusesWhatIsHeld() async throws {
        let f = try Fixture(), (id, turn, gate) = try await running(f)
        _ = try await poll(f, id)
        let outcome = Outcome()
        gate.decide("rates.example.test", .command) { outcome.set($0) }
        #expect(try await poll(f, id)["site_question"]?["by_command"] == .bool(true))
        _ = try await f.request("chat_stop", [("request_id", .str(id.uuidString)), ("turn_id", turn)])
        #expect(try await outcome.wait() == false)
        #expect(try await f.request("chat_sites")["sites"] == .array([]))
    }
}
