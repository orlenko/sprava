import Foundation

/// One turn's wall for the binder's sites (conversation.md 18.3.1). The proxy asks it about every host that is neither a
/// model host nor the vendor's; it answers at once from the binder's list and this turn's answers, or holds the connection
/// and puts a question to the person, which the conversation shows while it watches the turn. It also counts, per host
/// and caller, what the turn's summary lists. Nothing here is logged: hosts stay with the turn.
package final class AgentSiteGate: @unchecked Sendable {
    package typealias Caller = AgentEgressProxy.Caller
    package enum Answer: String, Sendable { case once, always, deny }
    /// How a host was let through or not, for the summary.
    package enum How: String, Sendable { case listed, once, denied, unanswered, refused }
    package struct Question: Sendable, Equatable {
        package let id: UUID
        package let host: String
        /// `.command` when a command asked: its wording says files can be sent there.
        package let caller: Caller
    }
    package struct Use: Sendable, Equatable {
        package let host: String
        package let caller: Caller
        package var connections = 0, refused = 0, sent = 0, received = 0
        package var how: How
    }

    package static let questionLimit = 4, noesLimit = 3, usesLimit = 200

    private struct Held { var question: Question; var asked: Date; var shown: Date?; var waiting: [(caller: Caller, done: @Sendable (Bool) -> Void)] }
    private let listed: @Sendable (String, Caller) -> Bool
    private let remember: @Sendable (String, Caller) -> Bool
    private let asks: Bool, timeout: TimeInterval, watchWindow: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var held: [Held] = []
    private var granted: [String: Bool] = [:] // host: whether commands too
    private var denied = Set<String>()
    private var noes = 0, ended = false
    private var watched: Date?
    private var tally: [Use] = []

    /// `listed` reads the binder's sites as they are now, so a removal counts at once; `remember` keeps an Always and says
    /// whether it could. `asks` is false for a turn nobody started from the conversation: nothing is ever asked in it.
    package init(asks: Bool, timeout: TimeInterval = 120, watchWindow: TimeInterval = 5, now: @escaping @Sendable () -> Date = { Date() },
                 listed: @escaping @Sendable (String, Caller) -> Bool, remember: @escaping @Sendable (String, Caller) -> Bool) {
        self.asks = asks; self.timeout = timeout; self.watchWindow = watchWindow; self.now = now
        self.listed = listed; self.remember = remember
    }

    /// Whether `caller` may reach `host`, a name in its one form; `done` may be called later, from any thread, exactly once.
    package func decide(_ host: String, _ caller: Caller, _ done: @escaping @Sendable (Bool) -> Void) {
        if lock.withLock({ ended }) { finish(host, caller, .refused, done, allowed: false); return }
        if listed(host, caller) { finish(host, caller, .listed, done); return }
        enum Verdict { case decided(Bool, How), ask(UUID), joined }
        let verdict: Verdict = lock.withLock {
            if ended { return .decided(false, .refused) }
            if let commands = granted[host], commands || caller == .agent { return .decided(true, .once) }
            if denied.contains(host) { return .decided(false, .denied) }
            if let index = held.firstIndex(where: { $0.question.host == host && ($0.question.caller == .command || caller == .agent) }) {
                held[index].waiting.append((caller, done)); return .joined
            }
            guard asks, noes < Self.noesLimit, held.count < Self.questionLimit,
                  let seen = watched, now().timeIntervalSince(seen) <= watchWindow else { return .decided(false, .refused) }
            let question = Question(id: UUID(), host: host, caller: caller)
            held.append(Held(question: question, asked: now(), shown: nil, waiting: [(caller, done)]))
            return .ask(question.id)
        }
        switch verdict {
        case .decided(let allowed, let how): finish(host, caller, how, done, allowed: allowed)
        case .ask(let id): expire(id) // One never shown, because the person stopped watching, ends too.
        case .joined: break
        }
    }

    /// The question to show now, if any. The conversation calls this as it polls the turn: that is what "watching" means,
    /// and a question's two minutes start the first time it is returned.
    package func question() -> Question? {
        let (current, expiry): (Question?, UUID?) = lock.withLock {
            let at = now()
            watched = at
            guard !held.isEmpty else { return (nil, nil) }
            if held[0].shown == nil { held[0].shown = at; return (held[0].question, held[0].question.id) }
            return (held[0].question, nil)
        }
        if let expiry { expire(expiry) }
        return current
    }

    /// The person's tap on the question with `id`; false when it is no longer asked.
    @discardableResult
    package func answer(_ id: UUID, _ answer: Answer) -> Bool { settle(id, answer) }

    /// The turn is over or stopped: everything held is refused, and nothing more is asked.
    package func end() {
        let waiting = lock.withLock { () -> [(String, Caller, @Sendable (Bool) -> Void)] in
            ended = true
            defer { held = [] }
            return held.flatMap { item in item.waiting.map { (item.question.host, $0.caller, $0.done) } }
        }
        for (host, caller, done) in waiting { finish(host, caller, .refused, done, allowed: false) }
    }

    /// What the turn reached, for its summary.
    package var uses: [Use] { lock.withLock { tally } }

    /// Bytes through an open tunnel, as they pass.
    package func count(_ host: String, _ caller: Caller, sent: Int = 0, received: Int = 0) {
        lock.withLock {
            guard let index = tally.firstIndex(where: { $0.host == host && $0.caller == caller }) else { return }
            tally[index].sent += sent; tally[index].received += received
        }
    }

    private func expire(_ id: UUID) {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.settle(id, nil) }
    }

    /// `answer` nil: no answer in time.
    @discardableResult
    private func settle(_ id: UUID, _ answer: Answer?) -> Bool {
        let outcome = lock.withLock { () -> (Held, Answer?)? in
            guard let index = held.firstIndex(where: { $0.question.id == id }) else { return nil }
            if answer == nil {
                // Two minutes from when it was shown; one waiting behind another is not timed until the person stops watching.
                let at = now(), unwatched = watched.map { at.timeIntervalSince($0) > watchWindow } ?? true
                if let shown = held[index].shown {
                    guard at.timeIntervalSince(shown) >= timeout - 0.001 else { return nil }
                } else {
                    guard unwatched, at.timeIntervalSince(held[index].asked) >= timeout - 0.001 else { return nil }
                }
            }
            return (held.remove(at: index), answer)
        }
        guard let (item, answer) = outcome else { return false }
        let host = item.question.host, commands = item.question.caller == .command
        var kept = false
        if answer == .always { kept = remember(host, item.question.caller) }
        let refusedOnes: [(String, Caller, @Sendable (Bool) -> Void)] = lock.withLock {
            switch answer {
            case .once?, .always?:
                granted[host] = (granted[host] ?? false) || commands
                return []
            case .deny?, nil:
                denied.insert(host); noes += 1
                if noes >= Self.noesLimit {
                    defer { held = [] }
                    return held.flatMap { other in other.waiting.map { (other.question.host, $0.caller, $0.done) } }
                }
                return []
            }
        }
        let how: How = answer == nil ? .unanswered : answer == .deny ? .denied : kept ? .listed : .once
        for waiter in item.waiting {
            if how == .listed || how == .once, waiter.caller == .command, !commands {
                decide(host, waiter.caller, waiter.done) // Claude's grant to read does not let a command send; it asks again.
            } else {
                finish(host, waiter.caller, how, waiter.done, allowed: how == .listed || how == .once)
            }
        }
        for (other, caller, done) in refusedOnes { finish(other, caller, .refused, done, allowed: false) }
        return true
    }

    private func finish(_ host: String, _ caller: Caller, _ how: How, _ done: @Sendable (Bool) -> Void, allowed: Bool = true) {
        // Every host reached is in the summary, so a turn reaches at most `usesLimit` of them; a script cycling through names
        // cannot grow the list without end.
        let counted: Bool = lock.withLock {
            guard let index = tally.firstIndex(where: { $0.host == host && $0.caller == caller }) ?? {
                guard tally.count < Self.usesLimit else { return nil }
                tally.append(Use(host: host, caller: caller, how: how)); return tally.count - 1
            }() else { return false }
            if allowed { tally[index].connections += 1 } else { tally[index].refused += 1 }
            tally[index].how = how
            return true
        }
        done(allowed && counted)
    }
}
