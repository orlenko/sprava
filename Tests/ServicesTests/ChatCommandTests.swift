import Foundation
import Testing
@testable import Services

private actor ChatFake {
    private(set) var received: [ChatSendRequest] = []
    private(set) var stopped: [(String, UUID)] = []
    private var continuation: AsyncStream<ChatReplyEvent>.Continuation?
    func send(_ request: ChatSendRequest) -> ChatTurn {
        received.append(request)
        let stream = AsyncStream<ChatReplyEvent>.makeStream()
        continuation = stream.continuation
        stream.continuation.yield(.activity("Reading the invented binder"))
        stream.continuation.yield(.textDelta("An invented answer"))
        return ChatTurn(binderID: request.binderID, requestID: request.requestID, turnID: UUID(), events: stream.stream)
    }
    func interrupt(_ binder: String, _ turn: UUID) {
        stopped.append((binder, turn)); continuation?.yield(.finished(.interrupted)); continuation?.finish()
    }
}

@Test func chatSendPreservesTheOriginalLineAndStreamsAnInterruptibleTurn() async throws {
    let fake = ChatFake()
    let commands = ChatCommands(send: { await fake.send($0) }, interrupt: { await fake.interrupt($0, $1) })
    let request = ChatSendRequest(binderID: "invented-binder", requestID: UUID(), text: "  Keep these exact words.\n")
    #expect(await fake.received.isEmpty) // Construction performs no work.
    let turn = try await commands.send(request)
    #expect(await fake.received == [request])
    try await commands.interrupt(binderID: turn.binderID, turnID: turn.turnID)
    var events: [ChatReplyEvent] = []; for await event in turn.events { events.append(event) }
    #expect(events == [.activity("Reading the invented binder"), .textDelta("An invented answer"), .finished(.interrupted)])
    let stopped = await fake.stopped
    #expect(stopped.count == 1 && stopped[0].0 == request.binderID && stopped[0].1 == turn.turnID)
}

@Test func chatRefusesBlankOversizedAndPathRequestsBeforeCallingItsBackend() async throws {
    let fake = ChatFake(), id = UUID()
    let commands = ChatCommands(send: { await fake.send($0) }, interrupt: { await fake.interrupt($0, $1) })
    for request in [ChatSendRequest(binderID: "invented-binder", requestID: id, text: " \n"),
                    ChatSendRequest(binderID: "invented-binder", requestID: id, text: String(repeating: "a", count: ChatCommands.maximumLineBytes + 1)),
                    ChatSendRequest(binderID: "/invented/binder", requestID: id, text: "A line")] {
        await #expect(throws: ChatCommandFailure.invalidRequest) { try await commands.send(request) }
    }
    await #expect(throws: ChatCommandFailure.invalidRequest) { try await commands.interrupt(binderID: "", turnID: id) }
    let received = await fake.received, stopped = await fake.stopped
    #expect(received.isEmpty && stopped.isEmpty)
}

@Test func chatDoesNotExposeAnotherBindersStreamOrUnexpectedBackendErrors() async throws {
    struct InventedBackendFailure: Error {}
    let request = ChatSendRequest(binderID: "invented-binder", requestID: UUID(), text: "A line")
    let wrong = ChatCommands(send: { r in
        ChatTurn(binderID: "another-invented-binder", requestID: r.requestID, turnID: UUID(), events: AsyncStream { $0.finish() })
    }, interrupt: { _, _ in throw InventedBackendFailure() })
    await #expect(throws: ChatCommandFailure.unavailable) { try await wrong.send(request) }
    await #expect(throws: ChatCommandFailure.unavailable) { try await wrong.interrupt(binderID: request.binderID, turnID: UUID()) }
    let cancelled = ChatCommands(send: { _ in throw CancellationError() }, interrupt: { _, _ in throw ChatCommandFailure.busy })
    await #expect(throws: ChatCommandFailure.cancelled) { try await cancelled.send(request) }
    await #expect(throws: ChatCommandFailure.busy) { try await cancelled.interrupt(binderID: request.binderID, turnID: UUID()) }
}

@Test func anAttachmentOnlyTurnKeepsCapturedReferencesAndStreamsCommittedChangeMetadata() async throws {
    let request = ChatSendRequest(binderID: "invented-binder", requestID: UUID(), text: "",
                                  attachments: [ChatAttachmentReference(captureID: "invented-app-capture")])
    let change = ChatBinderChange(operationIDs: ["invented-op"], summary: "Filed the invented form",
                                  undo: ChatUndoReference(batchID: "invented-turn-batch"))
    let commands = ChatCommands(send: { received in
        #expect(received == request)
        let events = AsyncStream<ChatReplyEvent> { c in
            c.yield(.binderChanged(change)); c.yield(.finished(.replied)); c.finish()
        }
        return ChatTurn(binderID: received.binderID, requestID: received.requestID, turnID: UUID(), events: events)
    }, interrupt: { _, _ in })
    let turn = try await commands.send(request)
    var events: [ChatReplyEvent] = []; for await event in turn.events { events.append(event) }
    #expect(events == [.binderChanged(change), .finished(.replied)])
}

@Test func invalidDuplicateAndOversizedAttachmentReferencesNeverReachTheBackend() async throws {
    let fake = ChatFake()
    let commands = ChatCommands(send: { await fake.send($0) }, interrupt: { await fake.interrupt($0, $1) })
    let duplicate = ChatAttachmentReference(captureID: "invented-capture")
    for attachments in [[ChatAttachmentReference(captureID: "/invented/intake/file.pdf")], [duplicate, duplicate],
                        (0...ChatCommands.maximumAttachments).map { ChatAttachmentReference(captureID: "invented-capture-\($0)") }] {
        let request = ChatSendRequest(binderID: "invented-binder", requestID: UUID(), text: "A line", attachments: attachments)
        await #expect(throws: ChatCommandFailure.invalidRequest) { try await commands.send(request) }
    }
    #expect(await fake.received.isEmpty)
}
