import Foundation
import ServiceManagement
@testable import SpravaApp
import Testing

/// Registering again waits for each unregister to complete before registering that service: a register sent 15 ms
/// after a synchronous unregister kept the previous build's launch constraint, and launchd refused the watcher after
/// every update (2026-10-28). Stand-in services only; nothing reaches launchd.
@Suite struct WatchRegistrationTests {
    /// The calls made, in order, and the completions held back for the test to deliver.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String] = []
        private var held: [@Sendable ((any Error)?) -> Void] = []
        var log: [String] { lock.withLock { made } }
        var heldCount: Int { lock.withLock { held.count } }
        func note(_ line: String) { lock.withLock { made.append(line) } }
        func hold(_ done: @escaping @Sendable ((any Error)?) -> Void) { lock.withLock { held.append(done) } }
        func release(_ error: (any Error)? = nil) { for done in lock.withLock({ held }) { done(error) } }

        /// Completes each unregister later, on another queue, with `error` for the plist named.
        func services(failing plist: String? = nil, with error: (any Error)? = nil, never: Bool = false,
                      twice: Bool = false) -> RuntimeStart.Services {
            RuntimeStart.Services(
                unregister: { name, done in
                    self.note("unregister \(name)")
                    if never { self.hold(done); return }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        self.note("removed \(name)")
                        done(name == plist ? error : nil)
                        if twice { done(nil) }
                    }
                },
                register: { name in self.note("register \(name)") })
        }
    }

    let runtime = RuntimeStart.runtimePlist, watch = RuntimeStart.watchPlist
    static let notFound = NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorJobNotFound))

    @Test func eachServiceIsRegisteredOnlyAfterItsUnregisterCompletes() {
        let calls = Calls()
        #expect(RuntimeStart.register(again: true, services: calls.services(), wait: 5) == nil)
        #expect(calls.log == ["unregister \(runtime)", "removed \(runtime)", "register \(runtime)",
                              "unregister \(watch)", "removed \(watch)", "register \(watch)"])
    }

    @Test func aFirstRegistrationUnregistersNothing() {
        let calls = Calls()
        #expect(RuntimeStart.register(again: false, services: calls.services(), wait: 5) == nil)
        #expect(calls.log == ["register \(runtime)", "register \(watch)"])
    }

    @Test func aServiceThatWasNotRegisteredIsRegistered() {
        let calls = Calls()
        #expect(RuntimeStart.register(again: true, services: calls.services(failing: watch, with: Self.notFound), wait: 5) == nil)
        #expect(calls.log.last == "register \(watch)")
    }

    @Test(arguments: [
        NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorInternalFailure)),
        NSError(domain: NSCocoaErrorDomain, code: Int(kSMErrorJobNotFound)),
    ])
    func anyOtherUnregisterFailureStopsAndIsReported(error: NSError) {
        let calls = Calls()
        let failure = RuntimeStart.register(again: true, services: calls.services(failing: runtime, with: error), wait: 5)
        #expect(failure?.contains(runtime) == true)
        #expect(!calls.log.contains { $0.hasPrefix("register") })
    }

    /// A completion that never comes: the wait ends at its bound, nothing is registered, and the completion delivered
    /// afterwards, once or twice, registers nothing either.
    @Test func anUnregisterThatNeverCompletesStopsAtTheBoundAndALateCompletionRegistersNothing() {
        let calls = Calls()
        let started = Date()
        let failure = RuntimeStart.register(again: true, services: calls.services(never: true), wait: 0.2)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(failure?.contains("did not finish removing") == true)
        #expect(calls.log == ["unregister \(runtime)"] && calls.heldCount == 1)
        calls.release()
        calls.release(Self.notFound)
        #expect(calls.log == ["unregister \(runtime)"])
    }

    @Test func aSecondCompletionIsIgnored() {
        let calls = Calls()
        #expect(RuntimeStart.register(again: true, services: calls.services(twice: true), wait: 5) == nil)
        #expect(calls.log.filter { $0.hasPrefix("register") } == ["register \(runtime)", "register \(watch)"])
    }

    @Test func onlyTheServiceManagementNotFoundCodeIsBenign() {
        #expect(RuntimeStart.notRegistered(Self.notFound))
        #expect(!RuntimeStart.notRegistered(NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorAlreadyRegistered))))
        #expect(!RuntimeStart.notRegistered(NSError(domain: NSOSStatusErrorDomain, code: Int(kSMErrorJobNotFound))))
    }
}
