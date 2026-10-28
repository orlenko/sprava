import Foundation
@testable import SpravaApp
import SpravaKit
import SwiftUI
import Testing

/// At launch, pages wait behind the starting screen and requests wait for the start, instead of timing out while
/// launchd brings the runtime up and showing "not answering in time" on every binder (2026-10-28). Stand-in launchd
/// and runtimes only; nothing is registered.
@MainActor
@Suite struct RuntimeStartingTests {
    typealias Launchd = RuntimeAutostartTests.Launchd

    @Test func onlyTheAppsLaunchWaitsAndItsFirstRunEndsIt() async {
        let launchd = Launchd(.notRegistered, works: .register)
        let keeper = launchd.keeper()
        // A model made for a test or a snapshot never shows the starting screen.
        #expect(!keeper.launching)
        keeper.beginLaunch()
        #expect(keeper.launching && keeper.launchBegan != nil)
        #expect(await keeper.ensureRunning() == .running)
        #expect(!keeper.launching && keeper.step == nil)
        // A later start (Health's Restart, a request that finds no runtime) is not a launch.
        keeper.beginLaunch()
        #expect(!keeper.launching)
    }

    @Test func aFailedLaunchStillEndsTheStartingScreen() async {
        let launchd = Launchd(.enabled)
        let keeper = launchd.keeper()
        keeper.beginLaunch()
        #expect(await keeper.ensureRunning() == .failed(RuntimeKeeper.noBeat))
        // The pages show again, with the failure in the banner, rather than waiting for ever.
        #expect(!keeper.launching)
    }

    @Test func aRequestDuringTheLaunchStartsTheRuntimeAndWaitsForIt() async {
        let launchd = Launchd(.notRegistered, works: .register)
        let keeper = launchd.keeper()
        keeper.beginLaunch()
        // The page's read can come before the app's own call to start: it starts the one shared run.
        await keeper.untilStarted()
        #expect(launchd.starts == [.register] && keeper.state == .running && !keeper.launching)
        _ = await keeper.ensureRunning()
        #expect(launchd.starts == [.register])
    }

    @Test func aRequestWaitsForAStartInProgressAndOtherwiseGoesAtOnce() async {
        let launchd = Launchd(.enabled, works: .kickstart)
        let keeper = launchd.keeper()
        // No launch and no run: nothing to wait for, and nothing is started.
        await keeper.untilStarted()
        #expect(launchd.starts.isEmpty && keeper.state == .idle)
        let started = Task { await keeper.restart() }
        while keeper.state != .starting { await Task.yield() }
        await keeper.untilStarted()
        // The start is over by then: launchd was asked, and the runtime beats.
        #expect(launchd.starts == [.kickstart])
        #expect(await started.value == .running && keeper.state == .running)
    }

    @Test func aRequestIsSentOnlyOnceTheStartIsOver() async throws {
        var events: [String] = []
        let client = RuntimeClient(answer: { text in
            events.append(try JSONParser.parse(text).value["command"]?.stringValue ?? "")
            return #"{"ok":true}"#
        }, untilStarted: { events.append("waited") })
        _ = try await client.global("unfiled", timeout: 5)
        _ = try await client.global("discard_card", [("card", .str("card-invented"))])
        _ = try await client.importFile(binder: URL(fileURLWithPath: "/Invented/kitchen-reno"), name: "quote.pdf",
                                        file: FileHandle.nullDevice)
        #expect(events == ["waited", "unfiled", "waited", "discard_card", "waited", "intake_drop"])
    }

    /// Health asks whether the runtime answers while it starts; that question must not wait for the start it reports.
    @Test func thePresenceCheckDoesNotWait() async {
        var waited = false
        let client = RuntimeClient(answer: { _ in #"{"ok":true}"# }, untilStarted: { waited = true })
        #expect(await client.presence() == .answers)
        #expect(!waited)
    }

    @Test func theStartingScreenSaysWhatTheStartIsDoing() {
        typealias Screen = StartingScreen<EmptyView>
        #expect(Screen.caption(nil).hasPrefix("Checking"))
        #expect(Screen.caption(.wait).hasPrefix("Waiting"))
        #expect(Screen.caption(.kickstart).hasPrefix("Restarting"))
        #expect(Screen.caption(.register) != Screen.caption(.reregister))
    }
}
