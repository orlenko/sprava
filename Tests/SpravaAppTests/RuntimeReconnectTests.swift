import Foundation
@testable import SpravaApp
import SpravaKit
import Testing

/// A request that finds no runtime: a read is sent once more on a new connection, a change never; a line a read left
/// saying the runtime is not running goes as soon as the runtime answers, and a change's failure stays. The app
/// launched before the runtime and kept saying so all day (error 4099). Stand-in runtimes, invented paths only.
@MainActor
@Suite struct RuntimeReconnectTests {
    /// Fails the next `failures` requests as a connection made before the runtime was there does.
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

    let kitchen = URL(fileURLWithPath: "/Invented/kitchen-reno", isDirectory: true)

    /// Over real XPC, to a name no service holds: XPC calls the error block on its own queue. A block isolated to the
    /// main actor trapped the app there whenever the runtime could not be reached.
    @Test func aRuntimeThatIsNotThereOverXPCIsReportedWithoutATrap() async throws {
        let client = RuntimeClient(serviceName: "ca.orlenko.sprava.test.absent-\(UUID().uuidString)")
        do {
            _ = try await client.global("ping", timeout: 10)
            Issue.record("an absent runtime answered")
        } catch let failure as RuntimeClient.Failure {
            #expect(failure.kind == .notRunning)
        }
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

    @Test func aChangeIsNeverSentTwiceAndSaysItMayNotBeSaved() async {
        let runtime = Flaky(failures: 1)
        do {
            _ = try await runtime.client.global("discard_card", [("card", .str("card-invented"))])
            Issue.record("the change went through")
        } catch {
            #expect("\(error)" == RuntimeClient.Failure.changeNotRunningLine)
        }
        #expect(runtime.sent == ["discard_card"])
        // A read's name with fields is a change too: binder_settings with a description saves it.
        let saving = Flaky(failures: 1)
        _ = try? await saving.client.command("binder_settings", binder: kitchen, [("description", .str("Invented quotes"))])
        #expect(saving.sent == ["binder_settings"])
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

    @Test func aReadLineThatQuotesTheFailureGoesWhenAnyRequestIsAnswered() async {
        let runtime = Flaky(failures: 2)
        let backup = BackupModel(client: runtime.client)
        await backup.load()
        #expect(backup.message == "Backup status could not be read: \(RuntimeClient.Failure.notRunningLine)")
        _ = await runtime.client.presence()
        #expect(backup.message == nil)
    }

    @Test func aChangeThatFoundNoRuntimeKeepsItsLineThroughLaterReads() async {
        let runtime = Flaky(failures: 1)
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: false)
        await actions.send("binder_settings", kitchen, [("description", .str("Invented quotes"))])
        #expect(actions.message == RuntimeClient.Failure.changeNotRunningLine)
        // The page's timer reads while the runtime is still down, then once it runs.
        runtime.failures = 2
        await actions.loadReview(kitchen)
        #expect(actions.message == RuntimeClient.Failure.changeNotRunningLine)
        await actions.loadReview(kitchen)
        #expect(actions.message == RuntimeClient.Failure.changeNotRunningLine)
    }

    /// Times out the next `stalls` requests, as a runtime held up behind a slow job does, then answers.
    @MainActor
    final class Stalled {
        var stalls: Int
        init(stalls: Int) { self.stalls = stalls }

        lazy var client = RuntimeClient(answer: { [self] text in
            let request = try JSONParser.parse(text).value
            if stalls > 0 {
                stalls -= 1
                let read = request.objectValue.map(RuntimeClient.isRead) ?? false
                throw RuntimeClient.Failure(message: read ? RuntimeClient.Failure.readTimedOutLine : RuntimeClient.Failure.changeTimedOutLine,
                                            kind: .timedOut)
            }
            return #"{"ok":true,"proposals":[],"ops":[]}"#
        })
    }

    /// The binder page kept "did not answer in time" after one slow read, while every read after it was answered.
    @Test func aReadThatTimedOutLeavesItsLineOnlyUntilTheRuntimeAnswers() async {
        let runtime = Stalled(stalls: 0)
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: false)
        runtime.stalls = 1
        await actions.loadReview(kitchen)
        #expect(actions.message == RuntimeClient.Failure.readTimedOutLine)
        await actions.loadReview(kitchen)
        #expect(actions.message == nil)
    }

    @Test func aChangeThatTimedOutKeepsItsLineThroughASlowReadAndALaterAnswer() async {
        let runtime = Stalled(stalls: 0)
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: false)
        runtime.stalls = 2
        await actions.send("binder_settings", kitchen, [("description", .str("Invented quotes"))])
        #expect(actions.message == RuntimeClient.Failure.changeTimedOutLine)
        await actions.loadReview(kitchen)
        #expect(actions.message == RuntimeClient.Failure.changeTimedOutLine)
        await actions.loadReview(kitchen)
        #expect(actions.message == RuntimeClient.Failure.changeTimedOutLine)
    }
}
