import Foundation
@testable import SpravaApp
import Testing

/// The app has its background part running without asking (decisions.md A16): what it does given the registration,
/// the heartbeat and the starts already made, and that a run is bounded. launchd is stood in for; nothing is registered.
@MainActor
@Suite struct RuntimeAutostartTests {
    typealias Step = RuntimeAutostart.Step

    @Test(arguments: [
        // A live heartbeat needs nothing, whoever started the runtime (a development run is not registered).
        (RuntimeAutostart.Registration.enabled, true, 0, false, Step.done),
        (.notRegistered, true, 0, false, .done),
        (.requiresApproval, false, 0, false, .needsApproval),
        (.notRegistered, false, 0, false, .register),
        (.notRegistered, false, 1, false, .register),
        (.notRegistered, false, 2, true, .giveUp),
        // Registered with no live beat: wait for launchd first, then kickstart, then register again, then stop.
        (.enabled, false, 0, false, .wait),
        (.enabled, false, 0, true, .kickstart),
        (.enabled, false, 1, false, .wait),
        (.enabled, false, 1, true, .reregister),
        (.enabled, false, 2, true, .giveUp),
    ])
    func theNextStep(registration: RuntimeAutostart.Registration, live: Bool, starts: Int, waited: Bool, step: Step) {
        #expect(RuntimeAutostart.next(registration, live: live, starts: starts, waited: waited) == step)
    }

    @Test func aLiveHeartbeatIsFreshFromALiveProcessAndAfterTheStart() {
        let now = Date()
        #expect(RuntimeAutostart.isLive(beatAt: now.addingTimeInterval(-20), pidAlive: true, now: now, since: nil))
        #expect(!RuntimeAutostart.isLive(beatAt: now.addingTimeInterval(-20), pidAlive: false, now: now, since: nil))
        // Two minutes without a beat is amber: not live, even with the process there (a hung runtime).
        #expect(!RuntimeAutostart.isLive(beatAt: now.addingTimeInterval(-130), pidAlive: true, now: now, since: nil))
        // After a start, the old runtime's beat does not count; a beat written to the second just before it does.
        #expect(!RuntimeAutostart.isLive(beatAt: now.addingTimeInterval(-5), pidAlive: true, now: now, since: now.addingTimeInterval(-2)))
        #expect(RuntimeAutostart.isLive(beatAt: now.addingTimeInterval(-2.5), pidAlive: true, now: now, since: now.addingTimeInterval(-2)))
    }

    /// launchd as the keeper sees it: a registration, a heartbeat that comes after the start that works, and the
    /// starts made, in order.
    final class Launchd: @unchecked Sendable {
        private let lock = NSLock()
        private var registration: RuntimeAutostart.Registration
        private var live: Bool
        private var made: [Step] = []
        /// The start after which a beat comes; nil for none.
        let works: Step?
        let failure: String?

        init(_ registration: RuntimeAutostart.Registration, live: Bool = false, works: Step? = nil, failure: String? = nil) {
            (self.registration, self.live, self.works, self.failure) = (registration, live, works, failure)
        }

        var starts: [Step] { lock.withLock { made } }

        var system: RuntimeKeeper.System {
            RuntimeKeeper.System(
                registration: { self.lock.withLock { self.registration } },
                live: { _ in self.lock.withLock { self.live } },
                start: { step in
                    self.lock.withLock {
                        self.made.append(step)
                        if self.failure != nil { return self.failure }
                        if step == .register || step == .reregister { self.registration = .enabled }
                        if step == self.works { self.live = true }
                        return nil
                    }
                })
        }

        @MainActor func keeper() -> RuntimeKeeper {
            let keeper = RuntimeKeeper(system: system)
            keeper.beatWait = .milliseconds(100)
            keeper.poll = .milliseconds(10)
            return keeper
        }
    }

    @Test func aRunningRuntimeIsLeftAlone() async {
        let launchd = Launchd(.enabled, live: true)
        let keeper = launchd.keeper()
        #expect(await keeper.ensureRunning() == .running)
        #expect(launchd.starts.isEmpty && keeper.state == .running)
    }

    @Test func anExplicitRestartRestartsEvenAProcessWithALiveHeartbeat() async {
        let launchd = Launchd(.enabled, live: true, works: .kickstart)
        let keeper = launchd.keeper()
        #expect(await keeper.restart() == .running)
        // A heartbeat can be live while the app cannot connect. Restart must not just return "running".
        #expect(launchd.starts == [.kickstart])
    }

    @Test func anUnregisteredRuntimeIsRegisteredWithoutAsking() async {
        let launchd = Launchd(.notRegistered, works: .register)
        let keeper = launchd.keeper()
        #expect(await keeper.ensureRunning() == .running)
        #expect(launchd.starts == [.register])
    }

    /// The case of 2026-10-14: launchd keeps failing to start a registered job whose record points at a deleted copy
    /// of the app; a kickstart does not help, registering again does.
    @Test func aRegisteredRuntimeThatDoesNotBeatIsKickstartedThenRegisteredAgain() async {
        let launchd = Launchd(.enabled, works: .reregister)
        let keeper = launchd.keeper()
        #expect(await keeper.ensureRunning() == .running)
        #expect(launchd.starts == [.kickstart, .reregister])
    }

    @Test func aRunGivesUpAfterTwoStartsAndDoesNotTryAgainUntilRestart() async {
        let launchd = Launchd(.enabled)
        let keeper = launchd.keeper()
        #expect(await keeper.ensureRunning() == .failed(RuntimeKeeper.noBeat))
        #expect(launchd.starts == [.kickstart, .reregister] && keeper.state == .failed(RuntimeKeeper.noBeat))
        // Another launch of a screen or a failed request reports the failure; it does not start again.
        #expect(await keeper.ensureRunning() == .failed(RuntimeKeeper.noBeat))
        #expect(launchd.starts.count == 2)
        // Health's Restart tries again, at once, and is bounded the same way.
        #expect(await keeper.restart() == .failed(RuntimeKeeper.noBeat))
        #expect(launchd.starts == [.kickstart, .reregister, .kickstart, .reregister])
    }

    @Test func aStartThatIsRefusedStopsWithTheReason() async {
        let launchd = Launchd(.notRegistered, failure: "Move Sprava to Applications first.")
        let keeper = launchd.keeper()
        #expect(await keeper.ensureRunning() == .failed("Move Sprava to Applications first."))
        #expect(launchd.starts == [.register])
    }

    @Test func approvalIsLeftToThePerson() async {
        let launchd = Launchd(.requiresApproval)
        let keeper = launchd.keeper()
        #expect(await keeper.ensureRunning() == .needsApproval)
        #expect(launchd.starts.isEmpty && keeper.state == .needsApproval)
        // Not a failure: the next request looks again, so an approval given meanwhile is used.
        #expect(await keeper.ensureRunning() == .needsApproval)
    }

    @Test func callsDuringARunShareIt() async {
        let launchd = Launchd(.notRegistered, works: .register)
        let keeper = launchd.keeper()
        async let first = keeper.ensureRunning()
        async let second = keeper.ensureRunning()
        let outcomes = await [first, second]
        #expect(outcomes == [.running, .running] && launchd.starts == [.register])
    }
}
