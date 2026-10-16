import BinderFormat
import Combine
import Foundation
import Services
@testable import SpravaApp
import SpravaKit
import Testing

/// The conversation on a binder's page, against a stand-in for the binder's back office (conversation.md §3,
/// §15 PR 6): lines are sent whole under one request id, replies stream into their own binder's thread, Stop asks
/// the binder to stop that turn, and nothing the person typed is lost when a line is not accepted. Invented binders.
@MainActor
@Suite struct BinderChatTests {
    /// A back office that hands each turn's events to the test.
    final class StandIn: @unchecked Sendable {
        private let lock = NSLock()
        private var _received: [ChatSendRequest] = []
        private var _stopped: [UUID] = []
        private var streams: [UUID: AsyncStream<ChatReplyEvent>.Continuation] = [:]
        var refuse: ChatCommandFailure?

        var received: [ChatSendRequest] { lock.withLock { _received } }
        var stopped: [UUID] { lock.withLock { _stopped } }

        var commands: ChatCommands {
            ChatCommands(send: { request in try self.send(request) }, interrupt: { _, turn in self.interrupt(turn) })
        }

        func send(_ request: ChatSendRequest) throws -> ChatTurn {
            try lock.withLock {
                _received.append(request)
                if let refuse { throw refuse }
                let (stream, continuation) = AsyncStream<ChatReplyEvent>.makeStream()
                let turn = UUID()
                streams[turn] = continuation
                return ChatTurn(binderID: request.binderID, requestID: request.requestID, turnID: turn, events: stream)
            }
        }

        func interrupt(_ turn: UUID) {
            lock.withLock { _stopped.append(turn) }
            emit(.finished(.interrupted), to: turn, end: true)
        }

        func emit(_ event: ChatReplyEvent, to turn: UUID? = nil, end: Bool = false) {
            let continuation = lock.withLock { turn.flatMap { streams[$0] } ?? streams.values.first }
            continuation?.yield(event)
            if end { continuation?.finish() }
        }

        func end() { lock.withLock { streams.values.forEach { $0.finish() } } }
    }

    static let folder = URL(fileURLWithPath: "/invented/binders/acme-books")
    static let other = URL(fileURLWithPath: "/invented/binders/harbor-house")

    func chat(_ standIn: StandIn, ids: [URL: String] = [folder: "acme-binder", other: "harbor-binder"],
              history: [BinderChat.Entry] = [], note: String? = nil) -> BinderChat {
        BinderChat(commands: standIn.commands, binderID: { ids[$0] }, readHistory: { _ in (history, note) })
    }

    func until(_ done: () -> Bool) async {
        for _ in 0..<2000 where !done() { await Task.yield(); try? await Task.sleep(for: .milliseconds(2)) }
        #expect(done())
    }

    @Test func aLineIsSentWholeAndItsReplyStreamsUntilFinished() async {
        let standIn = StandIn(), chat = chat(standIn)
        await chat.show(Self.folder)
        chat.draft = "  Keep these exact words.\n"
        #expect(chat.canSend)
        await chat.send()
        #expect(standIn.received.map(\.text) == ["  Keep these exact words.\n"])
        #expect(standIn.received.first?.binderID == "acme-binder")
        #expect(chat.draft.isEmpty && chat.isReplying && !chat.canSend)

        standIn.emit(.activity("Reading the invented lease"))
        standIn.emit(.textDelta("The invented lease "))
        standIn.emit(.textDelta("ends in March."))
        await until { chat.entries.last?.text == "The invented lease ends in March." }
        #expect(chat.entries.last?.activity == "Reading the invented lease")
        standIn.emit(.finished(.replied), end: true)
        await until { chat.entries.last?.state == .replied }
        #expect(chat.entries.map(\.speaker) == [.person, .binder])
        #expect(chat.entries.first?.state == .sent)
        #expect(chat.entries.last?.activity == nil)
        #expect(!chat.isReplying)
    }

    @Test func aStreamThatEndsWithoutFinishingIsNeverAReply() async {
        let standIn = StandIn(), chat = chat(standIn)
        await chat.show(Self.folder)
        chat.draft = "Summarize the invented letters"
        await chat.send()
        standIn.emit(.textDelta("Half an answer"))
        standIn.end()
        await until { chat.entries.last?.state == .incomplete }
        #expect(!chat.isReplying)
    }

    @Test func stopAsksForThatTurnAndChangesKeepTheirUndo() async {
        let standIn = StandIn()
        var undone: [String] = [], reloads = 0
        let chat = BinderChat(commands: standIn.commands, binderID: { _ in "acme-binder" },
                              undo: { reference, _ in undone.append(reference.batchID) }, readHistory: { _ in ([], nil) })
        chat.changed = { _ in reloads += 1 }
        await chat.show(Self.folder)
        chat.draft = "File the invented receipts"
        await chat.send()
        let change = ChatBinderChange(operationIDs: ["op-1"], summary: "Filed 2 invented receipts in receipts/",
                                      undo: ChatUndoReference(batchID: "batch-1"))
        standIn.emit(.binderChanged(change))
        await until { chat.entries.last?.changes == [change] }
        #expect(reloads == 1)

        await chat.stop()
        await until { chat.entries.last?.state == .stopped }
        #expect(standIn.stopped.count == 1)
        #expect(!chat.isReplying && !chat.isStopping)

        await chat.undo(change)
        #expect(undone == ["batch-1"] && chat.isUndone(change) && reloads == 2)
        await chat.undo(change)
        #expect(undone == ["batch-1"])
    }

    @Test func aLineNotAcceptedComesBackAndRetryRepeatsItsRequestID() async {
        let standIn = StandIn(), chat = chat(standIn)
        await chat.show(Self.folder)
        standIn.refuse = .busy
        chat.draft = "Renew the invented permit"
        await chat.send()
        guard case .notSent? = chat.entries.last?.state else { Issue.record("not marked as not sent"); return }
        #expect(chat.draft == "Renew the invented permit")
        #expect(!chat.isReplying)

        standIn.refuse = nil
        await chat.retry(chat.entries[0])
        #expect(chat.draft.isEmpty)   // the line put back leaves the composer once it is accepted
        #expect(standIn.received.count == 2)
        #expect(standIn.received[0].requestID == standIn.received[1].requestID)
        #expect(standIn.received[1].text == "Renew the invented permit")
        #expect(chat.entries.count == 2 && chat.entries[0].state == .sent && chat.isReplying)
    }

    @Test func eachBinderKeepsItsDraftAndAReplyStreamsIntoItsOwnThread() async {
        let standIn = StandIn(), chat = chat(standIn)
        await chat.show(Self.folder)
        chat.draft = "First invented question"
        await chat.send()
        await chat.show(Self.other)
        chat.draft = "A draft for the other binder"
        #expect(chat.entries.isEmpty && !chat.isReplying)
        standIn.emit(.textDelta("Answer for the first binder"))
        standIn.emit(.finished(.replied), end: true)
        await chat.show(Self.folder)
        await until { chat.entries.last?.state == .replied }
        #expect(chat.entries.last?.text == "Answer for the first binder")
        var redraws = 0
        let watching = chat.objectWillChange.sink { redraws += 1 }
        await chat.show(Self.other)
        #expect(redraws > 0)   // moving to a binder already read redraws the page
        watching.cancel()
        #expect(chat.draft == "A draft for the other binder" && chat.entries.isEmpty)
        #expect(standIn.stopped.isEmpty)   // leaving a page is not Stop
    }

    @Test func aMovedBinderKeepsItsThreadAndAReplacementStartsFresh() async {
        let standIn = StandIn()
        var ids: [URL: String] = [Self.folder: "acme-binder"]
        let chat = BinderChat(commands: standIn.commands, binderID: { ids[$0] }, readHistory: { _ in ([], nil) })
        await chat.show(Self.folder)
        chat.draft = "A draft typed before the move"
        // The same binder under a new folder: its draft comes along.
        let moved = URL(fileURLWithPath: "/invented/binders/acme-books-2026")
        ids = [moved: "acme-binder"]
        await chat.show(moved)
        #expect(chat.draft == "A draft typed before the move")
        // Another binder now at the first place: nothing of the first one's thread.
        ids[Self.folder] = "another-binder"
        await chat.show(Self.folder)
        #expect(chat.draft.isEmpty && chat.entries.isEmpty)
    }

    @Test func oneHugePieceOfAReplyIsCutToTheLimit() async {
        let standIn = StandIn(), chat = chat(standIn)
        await chat.show(Self.folder)
        chat.draft = "Read me everything"
        await chat.send()
        standIn.emit(.textDelta("é" + String(repeating: "x", count: BinderChat.maximumReplyBytes + 10)))
        standIn.emit(.textDelta("more after the cut"))
        standIn.emit(.finished(.replied), end: true)
        await until { chat.entries.last?.state == .replied }
        let text = chat.entries.last?.text ?? ""
        #expect(text.hasSuffix("[The rest of this reply is not shown.]"))
        #expect(!text.contains("more after the cut"))
        #expect(text.utf8.count <= BinderChat.maximumReplyBytes + 64)
        #expect(BinderChat.prefix(of: "aé", bytes: 2) == "a")
    }

    @Test func blankLinesAndBindersWithoutAnIdentityAreNotSent() async {
        let standIn = StandIn(), chat = chat(standIn, ids: [:])
        await chat.show(Self.folder)
        #expect(!chat.isAvailable)
        chat.draft = "An invented question"
        await chat.send()
        #expect(standIn.received.isEmpty && chat.entries.isEmpty)

        let available = self.chat(standIn)
        await available.show(Self.folder)
        available.draft = " \n "
        #expect(!available.canSend)
        await available.send()
        #expect(standIn.received.isEmpty)
    }

    @Test func savedHistoryIsShownAboveAndItsDamageNamed() async {
        let earlier = [BinderChat.Entry(id: UUID(), speaker: .person, text: "An earlier invented line", state: .earlier)]
        let chat = chat(StandIn(), history: earlier, note: "Some earlier messages could not be read; they were left as they are.")
        await chat.show(Self.folder)
        #expect(chat.entries == earlier)
        #expect(chat.historyNote?.hasPrefix("Some earlier messages") == true)
    }

    @Test func historyIsReadFromTheBindersFilesDisplayOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-chat-\(UUID().uuidString)")
        let dir = folder.appendingPathComponent(".sprava/conversation")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let line = try ConversationMessage(id: "0199e9e6-3c00-7000-8000-000000000001", turn: "0199e9e6-3c00-7000-8000-000000000002",
                                           at: "2026-10-16T12:00:00Z", speaker: .person, origin: .app, text: "An earlier invented line",
                                           device: "device-example", requestID: "0199e9e6-3c00-7000-8000-000000000003").lines()
        try (line.reduce(Data(), +) + Data("not a record\n".utf8)).write(to: dir.appendingPathComponent("2026-10.ndjson"))
        let (entries, note) = await BinderChat.history(folder)
        #expect(entries.map(\.text) == ["An earlier invented line"])
        #expect(entries.map(\.state) == [.earlier])
        #expect(note != nil)
    }
}
