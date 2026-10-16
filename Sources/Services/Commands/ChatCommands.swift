import Foundation

/// An authenticated line from the app's binder composer (conversation §§3.2, 6.2).
/// binderID is the binder owner's opaque identity, never a path or a display name.
/// Repeating requestID must recover the same recorded turn, never append or execute the line twice.
public struct ChatSendRequest: Sendable, Equatable {
    public let binderID: String
    public let requestID: UUID
    public let text: String
    public let attachments: [ChatAttachmentReference]
    public init(binderID: String, requestID: UUID, text: String, attachments: [ChatAttachmentReference] = []) {
        self.binderID = binderID; self.requestID = requestID; self.text = text; self.attachments = attachments
    }
}

public enum ChatCommandFailure: Error, Sendable, Equatable {
    case invalidRequest, busy, unavailable, cancelled
}
public enum ChatTurnCompletion: Sendable, Equatable { case replied, interrupted }

/// Text is for this binder's UI only, never logging, notifications or the heartbeat (§3.3).
/// End-of-stream without finished/failed is an incomplete turn, never a successful reply.
public enum ChatReplyEvent: Sendable, Equatable {
    case textDelta(String)
    case activity(String)
    case binderChanged(ChatBinderChange)
    case finished(ChatTurnCompletion)
    case failed(ChatCommandFailure)
}

public struct ChatTurn: Sendable {
    public let binderID: String
    public let requestID: UUID
    public let turnID: UUID
    public let events: AsyncStream<ChatReplyEvent>
    public init(binderID: String, requestID: UUID, turnID: UUID, events: AsyncStream<ChatReplyEvent>) {
        self.binderID = binderID; self.requestID = requestID; self.turnID = turnID; self.events = events
    }
}

/// The screen's injectable send/stream/Stop contract; no engine, transcript or XPC implementation here.
/// A real send handler returns only AFTER the original line and turn identity are durably recorded by
/// BinderStore. This return is acceptance, not completion; the stream reports later engine progress.
/// Dropping a UI subscription is not Stop. Interrupt is scoped to binderID + turnID, is repeatable,
/// and completes only when the supervisor has stopped that turn; earlier applied changes keep Undo (§11).
public struct ChatCommands: Sendable {
    public typealias Send = @Sendable (ChatSendRequest) async throws -> ChatTurn
    public typealias Interrupt = @Sendable (_ binderID: String, _ turnID: UUID) async throws -> Void
    public static let maximumLineBytes = 4 * 1024 * 1024
    public static let maximumAttachments = 64
    private let sendLine: Send
    private let interruptTurn: Interrupt
    public init(send: @escaping Send, interrupt: @escaping Interrupt) {
        sendLine = send; interruptTurn = interrupt
    }
    public func send(_ request: ChatSendRequest) async throws -> ChatTurn {
        guard Self.validID(request.binderID), request.text.utf8.count <= Self.maximumLineBytes,
              request.attachments.count <= Self.maximumAttachments,
              request.attachments.allSatisfy({ Self.validID($0.captureID) }),
              Set(request.attachments.map(\.captureID)).count == request.attachments.count,
              !request.attachments.isEmpty || !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatCommandFailure.invalidRequest
        }
        return try await perform {
            let turn = try await sendLine(request)
            guard turn.binderID == request.binderID, turn.requestID == request.requestID else { throw ChatCommandFailure.unavailable }
            return turn
        }
    }
    public func interrupt(binderID: String, turnID: UUID) async throws {
        guard Self.validID(binderID) else { throw ChatCommandFailure.invalidRequest }
        try await perform { try await interruptTurn(binderID, turnID) }
    }
    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 1024 && !id.contains("/") && !id.contains("\\") &&
            !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private func perform<T>(_ action: () async throws -> T) async throws -> T {
        do { try Task.checkCancellation(); return try await action() }
        catch is CancellationError { throw ChatCommandFailure.cancelled }
        catch let error as ChatCommandFailure { throw error }
        catch { throw ChatCommandFailure.unavailable }
    }
}
