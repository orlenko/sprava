import Foundation
import Testing
@testable import Brains

/// A turn's questions about new sites, and the binder's list behind them (conversation.md 18.3.1). Hosts are invented.
@Suite struct AgentSiteGateTests {
    /// What a held connection was told, once it is told.
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock(); private var value: Bool?
        var result: Bool? { lock.withLock { value } }
        func set(_ allowed: Bool) { lock.withLock { precondition(value == nil, "told twice"); value = allowed } }
        func wait() -> Bool? {
            for _ in 0..<200 { if let result { return result }; usleep(10_000) }
            return result
        }
    }

    final class Kept: @unchecked Sendable {
        private let lock = NSLock(); private var hosts: [String: Bool] = [:]
        var all: [String: Bool] { lock.withLock { hosts } }
        func add(_ host: String, _ caller: AgentEgressProxy.Caller) -> Bool { lock.withLock { hosts[host] = (hosts[host] ?? false) || caller == .command }; return true }
        func has(_ host: String, _ caller: AgentEgressProxy.Caller) -> Bool { lock.withLock { hosts[host].map { $0 || caller == .agent } ?? false } }
    }

    static func gate(asks: Bool = true, timeout: TimeInterval = 120, kept: Kept = Kept()) -> AgentSiteGate {
        AgentSiteGate(asks: asks, timeout: timeout, listed: { kept.has($0, $1) }, remember: { kept.add($0, $1) })
    }

    func ask(_ gate: AgentSiteGate, _ host: String, _ caller: AgentEgressProxy.Caller = .agent) -> Outcome {
        let outcome = Outcome()
        gate.decide(host, caller) { outcome.set($0) }
        return outcome
    }

    @Test func aNewSiteWaitsForTheTapAndAlwaysKeepsIt() throws {
        let kept = Kept(), gate = Self.gate(kept: kept)
        _ = gate.question()
        let held = ask(gate, "docs.example-invoicing.test")
        let second = ask(gate, "docs.example-invoicing.test")
        #expect(held.result == nil && second.result == nil)
        let question = try #require(gate.question())
        #expect(question.host == "docs.example-invoicing.test" && question.caller == .agent)
        #expect(gate.answer(question.id, .always))
        #expect(held.wait() == true && second.wait() == true)
        #expect(kept.all == ["docs.example-invoicing.test": false])
        #expect(!gate.answer(question.id, .deny))
        #expect(gate.question() == nil)
        #expect(ask(gate, "docs.example-invoicing.test").wait() == true)
        #expect(gate.uses == [AgentSiteGate.Use(host: "docs.example-invoicing.test", caller: .agent, connections: 3, how: .listed)])
    }

    @Test func onceLastsTheTurnAndDenyIsNotAskedAgain() throws {
        let kept = Kept(), gate = Self.gate(kept: kept)
        _ = gate.question()
        let first = ask(gate, "rates.example.test")
        #expect(gate.answer(try #require(gate.question()).id, .once))
        #expect(first.wait() == true)
        #expect(ask(gate, "rates.example.test").wait() == true)
        #expect(kept.all.isEmpty)
        let denied = ask(gate, "tracker.example.test")
        #expect(gate.answer(try #require(gate.question()).id, .deny))
        #expect(denied.wait() == false)
        #expect(ask(gate, "tracker.example.test").wait() == false)
        #expect(gate.question() == nil)
    }

    @Test func claudesGrantToReadAsksAgainBeforeACommandSends() throws {
        let kept = Kept(), gate = Self.gate(kept: kept)
        _ = gate.question()
        let reading = ask(gate, "api.example-invoicing.test", .agent)
        let command = ask(gate, "api.example-invoicing.test", .command)
        let first = try #require(gate.question())
        #expect(first.caller == .agent)
        #expect(gate.answer(first.id, .always))
        #expect(reading.wait() == true)
        #expect(command.result == nil)
        let second = try #require(gate.question())
        #expect(second.host == "api.example-invoicing.test" && second.caller == .command)
        #expect(gate.answer(second.id, .always))
        #expect(command.wait() == true)
        #expect(kept.all == ["api.example-invoicing.test": true])
    }

    @Test func nobodyWatchingMeansNoQuestion() {
        #expect(ask(Self.gate(), "docs.example.test").wait() == false) // never polled
        #expect(ask(Self.gate(asks: false), "docs.example.test").wait() == false)
        let gate = Self.gate(asks: false)
        _ = gate.question()
        #expect(ask(gate, "docs.example.test").wait() == false)
        #expect(gate.uses.first?.how == .refused)
    }

    @Test func noAnswerInTimeIsANoAndThreeNoesEndTheAsking() throws {
        let gate = Self.gate(timeout: 0.2)
        _ = gate.question()
        let first = ask(gate, "a.example.test")
        _ = gate.question()
        #expect(first.wait() == false)
        #expect(gate.uses.first?.how == .unanswered)
        _ = gate.question()
        let second = ask(gate, "b.example.test"), queued = ask(gate, "c.example.test")
        #expect(gate.answer(try #require(gate.question()).id, .deny))
        #expect(second.wait() == false)
        // The third no ends asking: what waited behind it is refused, and nothing new is asked.
        #expect(gate.answer(try #require(gate.question()).id, .deny))
        #expect(queued.wait() == false)
        let fourth = ask(gate, "d.example.test")
        #expect(fourth.wait() == false)
        #expect(gate.question() == nil)
    }

    @Test func aWaitingQuestionIsNotTimedWhileTheFirstIsShown() throws {
        let gate = Self.gate(timeout: 0.3)
        _ = gate.question()
        let first = ask(gate, "a.example.test"), behind = ask(gate, "b.example.test")
        let shown = try #require(gate.question())
        usleep(200_000); _ = gate.question()
        #expect(gate.answer(shown.id, .once))
        #expect(first.wait() == true)
        usleep(200_000)
        let next = try #require(gate.question())
        #expect(next.host == "b.example.test")
        #expect(behind.result == nil)
        #expect(gate.answer(next.id, .once))
        #expect(behind.wait() == true)
    }

    @Test func atMostFourQuestionsWaitAndTheEndRefusesThem() {
        let gate = Self.gate()
        _ = gate.question()
        let waiting = (1...4).map { ask(gate, "s\($0).example.test") }
        #expect(ask(gate, "s5.example.test").wait() == false)
        #expect(waiting.allSatisfy { $0.result == nil })
        gate.end()
        #expect(waiting.allSatisfy { $0.wait() == false })
        #expect(gate.question() == nil)
    }

    @Test func bytesAreCountedPerHostAndCaller() {
        let kept = Kept(); _ = kept.add("files.example.test", .command)
        let gate = Self.gate(kept: kept)
        #expect(ask(gate, "files.example.test", .command).wait() == true)
        gate.count("files.example.test", .command, sent: 1200)
        gate.count("files.example.test", .command, received: 300)
        gate.count("other.example.test", .command, sent: 5)
        #expect(gate.uses == [AgentSiteGate.Use(host: "files.example.test", caller: .command, connections: 1, sent: 1200, received: 300, how: .listed)])
    }

    @Test func theBindersSitesAreKeptPerConnectionAndGoWithIt() throws {
        let f = try ClaudeReadConnectionTests.Fixture()
        let scope = try f.connections.enable(folder: f.folder, documents: true, intake: true, files: true)
        try f.connections.allowSite(scope, host: "docs.example.test", commands: false)
        #expect(try f.connections.allowsSite(scope, host: "docs.example.test", caller: .agent))
        #expect(try !f.connections.allowsSite(scope, host: "docs.example.test", caller: .command))
        try f.connections.allowSite(scope, host: "docs.example.test", commands: true)
        try f.connections.allowSite(scope, host: "docs.example.test", commands: false) // never narrows
        #expect(try f.connections.allowsSite(scope, host: "docs.example.test", caller: .command))
        #expect(throws: (any Error).self) { try f.connections.allowSite(scope, host: "api.anthropic.com", commands: false) }
        #expect(throws: (any Error).self) { try f.connections.allowSite(scope, host: "Docs.example.test.", commands: false) }
        // Changing the sharing choices keeps the list; removing a site or disconnecting does not.
        let changed = try f.connections.enable(folder: f.folder, documents: true, intake: true, files: true)
        #expect(try f.connections.sites(changed).map(\.host) == ["docs.example.test"])
        #expect(throws: ClaudeReadConnections.Refused.changed) { try f.connections.allowSite(scope, host: "old.example.test", commands: false) }
        try f.connections.allowSite(changed, host: "rates.example.test", commands: false)
        try f.connections.removeSite(changed, host: "docs.example.test")
        #expect(try f.connections.sites(changed).map(\.host) == ["rates.example.test"])
        try f.connections.disable(changed)
        let again = try f.connections.enable(folder: f.folder, documents: true, intake: true, files: true)
        #expect(try f.connections.sites(again).isEmpty)
    }

    @Test func aBinderKeepsAtMostTwoHundredSites() throws {
        let f = try ClaudeReadConnectionTests.Fixture()
        let scope = try f.connections.enable(folder: f.folder, documents: true, intake: true, files: true)
        for n in 0..<ClaudeReadConnections.maximumSites { try f.connections.allowSite(scope, host: "s\(n).example.test", commands: false) }
        #expect(throws: ClaudeReadConnections.Refused.tooManySites) { try f.connections.allowSite(scope, host: "more.example.test", commands: false) }
        try f.connections.allowSite(scope, host: "s1.example.test", commands: true)
    }
}
