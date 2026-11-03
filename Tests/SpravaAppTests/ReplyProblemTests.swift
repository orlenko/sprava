import AppKit
import Foundation
import Services
@testable import SpravaApp
import SwiftUI
import Testing

private final class Holding: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    var value: Bool {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}

/// A reply that did not finish says so in a Notice, and nothing it offers sends the person's words again: a lost contact
/// does not prove a turn stopped, and its changes reach the page only with its result. Invented binders.
@MainActor
extension BinderChatTests {
    private func failedReply(_ failure: ChatCommandFailure?, words: String = "Pay the invented plumber") async -> (StandIn, BinderChat) {
        let standIn = StandIn(), chat = chat(standIn)
        await chat.show(Self.folder)
        chat.draft = words
        await chat.send()
        await until { chat.isReplying }
        if let failure { standIn.emit(.failed(failure)) } else { standIn.end() }
        await until { !chat.isReplying }
        return (standIn, chat)
    }

    @Test(arguments: [
        ("exit_unconfirmed", [ReplyProblem.Action.restart]),
        ("authentication", [.openAssistant, .editAndSend]), ("token_missing", [.openAssistant, .editAndSend]),
        ("setup", [.openAssistant, .editAndSend]), ("usage_limit", [.openAssistant, .editAndSend]),
        ("no_quota", [.openAssistant, .editAndSend]), ("protocol", [.openAssistant, .editAndSend]),
        ("binder_unavailable", []),
        ("engine", [.editAndSend]), ("deadline", [.editAndSend]), ("a-code-this-build-does-not-know", [.editAndSend]),
    ]) func eachFailureOffersWhatCanHelpIt(reason: String, offers: [ReplyProblem.Action]) async throws {
        let (_, chat) = await failedReply(.turnFailed(reason))
        let reply = try #require(chat.entries.last)
        #expect(chat.actions(for: reply) == offers)
        #expect(reply.problem?.outcomeUnknown == false)
    }

    @Test func noFailureOffersANewTurnOnItsOwn() async throws {
        let (standIn, chat) = await failedReply(.turnFailed("engine"))
        let reply = try #require(chat.entries.last)
        chat.putBack(reply)
        #expect(chat.draft == "Pay the invented plumber")
        #expect(standIn.received.count == 1)
    }

    @Test func wordsPutBackAreANewTurnWithANewRequest() async throws {
        let (standIn, chat) = await failedReply(.turnFailed("engine"))
        chat.putBack(try #require(chat.entries.last))
        await chat.send()
        #expect(standIn.received.count == 2 && standIn.received[0].requestID != standIn.received[1].requestID)
        #expect(standIn.received[1].text == "Pay the invented plumber")
    }

    @Test func wordsNeverReplaceWhatIsInTheBox() async throws {
        let (_, chat) = await failedReply(.turnFailed("engine"))
        chat.draft = "Something newer"
        chat.putBack(try #require(chat.entries.last))
        #expect(chat.draft == "Something newer")
        #expect(chat.message?.contains("already holds text") == true)
    }

    @Test func aBrokenContactAndAStreamThatEndsLeaveOnlyAQuestion() async throws {
        for failure in [ChatCommandFailure.unavailable, nil] {
            let (standIn, chat) = await failedReply(failure)
            chat.reattach = { binder, request, turn, _ in
                ChatTurn(binderID: binder, requestID: request, turnID: turn, events: AsyncStream { $0.finish() })
            }
            let reply = try #require(chat.entries.last)
            #expect(chat.actions(for: reply) == [.checkReply])
            #expect(reply.problem?.outcomeUnknown == true)
            chat.putBack(reply)
            #expect(chat.draft.isEmpty && standIn.received.count == 1)
        }
    }

    @Test func checkingAReplyReadsItsResultUnderTheSameRequestAndSendsNothing() async throws {
        let (standIn, chat) = await failedReply(.unavailable)
        let original = try #require(chat.entries.last)
        let (events, result) = AsyncStream<ChatReplyEvent>.makeStream()
        var asked: (UUID, UUID)?
        chat.reattach = { binder, request, turn, _ in
            asked = (request, turn)
            return ChatTurn(binderID: binder, requestID: request, turnID: turn, events: events)
        }
        chat.checkReply(original)
        #expect(asked?.0 == standIn.received[0].requestID && asked?.1 == original.id)
        #expect(chat.isReplying)
        result.yield(.textDelta("The invented plumber is paid."))
        result.yield(.finished(.replied))
        result.finish()
        await until { !chat.isReplying }
        #expect(standIn.received.count == 1 && chat.entries.count == 2)
        #expect(chat.entries.last?.state == .replied && chat.entries.last?.text == "The invented plumber is paid.")
        #expect(chat.entries.last?.problem == nil)
    }

    @Test func aCheckThatLearnsTheTurnFailedThenOffersTheWords() async throws {
        let (_, chat) = await failedReply(.unavailable)
        chat.reattach = { binder, request, turn, _ in
            ChatTurn(binderID: binder, requestID: request, turnID: turn, events: AsyncStream {
                $0.yield(.failed(.turnFailed("engine"))); $0.finish()
            })
        }
        chat.checkReply(try #require(chat.entries.last))
        await until { chat.entries.last?.problem?.outcomeUnknown == false }
        await until { !chat.isReplying }
        #expect(chat.actions(for: try #require(chat.entries.last)) == [.editAndSend])
    }

    /// A line retried after a later one was sent gets its reply last, so the line just above a reply may not be its own.
    @Test func wordsComeFromTheLineTheReplyAnswersNotTheOneAboveIt() async throws {
        let standIn = StandIn(), chat = chat(standIn)
        await chat.show(Self.folder)
        standIn.refuse = .unavailable
        chat.draft = "First invented line"
        await chat.send()
        chat.draft = "Second invented line"
        await chat.send()
        standIn.refuse = nil
        let first = try #require(chat.entries.first { $0.text == "First invented line" })
        await chat.retry(first)
        await until { chat.isReplying }
        standIn.emit(.failed(.turnFailed("engine")))
        await until { !chat.isReplying }
        let reply = try #require(chat.entries.last)
        #expect(reply.speaker == .binder)
        chat.draft = ""
        chat.putBack(reply)
        #expect(chat.draft == "First invented line")
    }

    @Test func anOlderFailureOffersNothing() async throws {
        let (standIn, chat) = await failedReply(.turnFailed("engine"))
        let old = try #require(chat.entries.last)
        chat.draft = "A newer invented line"
        await chat.send()
        await until { chat.isReplying }
        #expect(chat.actions(for: old).isEmpty)
        standIn.emit(.finished(.replied), to: nil)
        chat.putBack(old)
        #expect(chat.draft.isEmpty)
    }

    /// A line refused as busy comes after the reply, and must not take away what clears the trouble.
    @Test func aRefusedLineKeepsTheWayOutOfTheTrouble() async throws {
        for (failure, offer) in [(ChatCommandFailure.turnFailed("exit_unconfirmed"), ReplyProblem.Action.restart), (.unavailable, .checkReply)] {
            let (standIn, chat) = await failedReply(failure)
            chat.reattach = { binder, request, turn, _ in
                ChatTurn(binderID: binder, requestID: request, turnID: turn, events: AsyncStream { $0.finish() })
            }
            let reply = try #require(chat.entries.last)
            standIn.refuse = .busy
            chat.draft = "Another invented line"
            await chat.send()
            #expect(chat.entries.last?.isNotSent == true)
            #expect(chat.actions(for: reply) == [offer])
        }
    }

    /// Words put back are what the box shows. They are not the line being retried, whose acceptance would clear the box and
    /// whose refusal would turn the next Send into that line's retry.
    @Test func wordsPutBackWhileAnOlderLineIsRetriedStayAndAreWhatIsSent() async throws {
        let standIn = StandIn()
        let (entered, arrived) = AsyncStream<Void>.makeStream()
        let (release, released) = AsyncStream<Void>.makeStream()
        let holding = Holding()
        let commands = ChatCommands(send: { request in
            if holding.value { arrived.yield(); for await _ in release { break } }
            return try standIn.send(request)
        }, interrupt: { _, _ in })
        let chat = BinderChat(commands: commands, binderID: { _ in "acme-binder" }, readHistory: { _ in ([], nil) })
        await chat.show(Self.folder)
        standIn.refuse = .unavailable
        chat.draft = "Older invented line"
        await chat.send()
        standIn.refuse = nil
        chat.draft = "Newer invented line"
        await chat.send()
        await until { chat.isReplying }
        standIn.emit(.failed(.turnFailed("engine")))
        await until { !chat.isReplying }
        let reply = try #require(chat.entries.last)
        let older = try #require(chat.entries.first { $0.text == "Older invented line" })
        // The older line's Retry is refused, so its words return to the box; Send then retries it and empties the box.
        standIn.refuse = .unavailable
        await chat.retry(older)
        #expect(chat.draft == "Older invented line")
        standIn.refuse = nil
        holding.value = true
        let retrying = Task { await chat.send() }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        #expect(chat.draft.isEmpty)
        chat.putBack(reply)
        #expect(chat.draft == "Newer invented line")
        released.yield()
        await retrying.value
        #expect(chat.draft == "Newer invented line")
    }

    /// Nothing may promise an Undo a change may not have.
    @Test func aFailureAfterChangesSaysToLookAndPromisesNoUndo() throws {
        var entry = BinderChat.Entry(id: UUID(), speaker: .binder, text: "", state: .failed("It stopped."))
        let problem = ReplyProblem(.turnFailed("engine"))
        #expect(!problem.words(for: entry).detail.contains("made changes"))
        entry.changesCut = true
        let detail = problem.words(for: entry).detail
        #expect(detail.contains("may already have made changes") && !detail.contains("Undo"))
        #expect(ReplyProblem.lostTouch.words(for: entry).detail.contains("may already have made changes"))
    }
}

/// The first trouble banner measured its words at the almost-no-width SwiftUI gives a window's minimum, asked for a very
/// tall window, and pushed the page and the sidebar above the top of the screen.
@MainActor
@Suite struct NoticeLayoutTests {
    @Test func aLongNoticeDoesNotRaiseTheWindowsMinimumHeight() {
        let words = Array(repeating: "Sprava's background part did not start.", count: 8).joined(separator: " ")
        let page = VStack(spacing: 0) {
            Notice(level: .broken, title: words) { Button("Restart") {} }
            Color.clear.frame(minHeight: 100)
        }
        let least = NSHostingController(rootView: page).sizeThatFits(in: CGSize(width: 10, height: 10))
        #expect(least.height < 400)
    }
}
