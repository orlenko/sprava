import Foundation
@testable import SpravaApp
import SpravaKit
import Testing

/// A request that finds no runtime: a read is sent once more on a new connection, a change never; and a page's line
/// saying the runtime is not running goes as soon as the runtime answers. The app launched before the runtime and kept
/// saying so all day (error 4099). Stand-in runtimes only.
@MainActor
@Suite struct RuntimeReconnectTests {
    /// Fails the first `failures` requests as a connection made before the runtime was there does.
    @MainActor
    final class Flaky {
        var failures: Int
        var sent: [String] = []
        init(failures: Int) { self.failures = failures }

        lazy var client = RuntimeClient(answer: { [self] text in
            let name = try JSONParser.parse(text).value["command"]?.stringValue ?? ""
            sent.append(name)
            if failures > 0 {
                failures -= 1
                throw RuntimeClient.Failure.notRunning(NSError(domain: NSCocoaErrorDomain, code: 4099))
            }
            switch name {
            case "unfiled": return #"{"ok":true,"cards":[]}"#
            case "readings": return #"{"ok":true,"readings":[]}"#
            default: return #"{"ok":true}"#
            }
        })
    }

    @Test func aReadThatFindsNoRuntimeIsSentOnceMore() async throws {
        let runtime = Flaky(failures: 1)
        _ = try await runtime.client.global("unfiled", timeout: 5)
        #expect(runtime.sent == ["unfiled", "unfiled"])
        // Only once more: a runtime that is really not there fails the read.
        let absent = Flaky(failures: 5)
        await #expect(throws: RuntimeClient.Failure.self) { _ = try await absent.client.global("unfiled", timeout: 5) }
        #expect(absent.sent == ["unfiled", "unfiled"])
    }

    @Test func aChangeIsNeverSentTwice() async {
        let runtime = Flaky(failures: 1)
        await #expect(throws: RuntimeClient.Failure.self) {
            _ = try await runtime.client.global("discard_card", [("card", .str("card-invented"))])
        }
        #expect(runtime.sent == ["discard_card"])
    }

    @Test func theInboxDropsTheNotRunningLineOnceTheRuntimeAnswers() async {
        // Both tries of the first read fail: the runtime is not up yet.
        let runtime = Flaky(failures: 2)
        let inbox = InboxModel(client: runtime.client, support: URL(fileURLWithPath: "/Invented/support"))
        await inbox.load()
        #expect(inbox.message == RuntimeClient.Failure.notRunningLine)
        await inbox.load()
        #expect(inbox.message == nil)
        // A line about something else stays.
        inbox.message = "Filed. Review it on the binder's page."
        await inbox.load()
        #expect(inbox.message == "Filed. Review it on the binder's page.")
    }

    @Test func aLineThatQuotesTheFailureGoesToo() async {
        let runtime = Flaky(failures: 0)
        let backup = BackupModel(client: runtime.client)
        backup.message = "Backup status could not be read: \(RuntimeClient.Failure.notRunningLine)"
        _ = try? await runtime.client.global("ping", timeout: 2)
        #expect(backup.message == nil)
    }
}
