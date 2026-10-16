import Foundation

/// An app capture reference, never a file path. This value alone proves no authority.
/// Before acceptance, the runtime resolves it through Capture's owner, verifies authenticated app origin
/// and this binder's scope, and records the resolved references with the line. The engine never opens it.
public struct ChatAttachmentReference: Sendable, Equatable {
    public let captureID: String
    public init(captureID: String) { self.captureID = captureID }
}

/// An opaque reference to BinderStore's committed turn batch and expected-state Undo, not inverse ops.
/// The runtime must resolve it in this turn's binder and refuse stale or mismatched receipts.
/// A non-nil reference offers Undo; it never promises that later binder edits cannot make Undo unavailable.
public struct ChatUndoReference: Sendable, Equatable {
    public let batchID: String
    public init(batchID: String) { self.batchID = batchID }
}

/// Emitted only after BinderStore commits the batch, including after an interrupted turn's partial work.
/// IDs come from that committed receipt; summary is plain UI text, never a command or a log message.
/// The screen refreshes its binder reader and uses the opaque reference for its Undo control.
/// Actual persistence, Undo execution and capture resolution are separate owning-target adapters.
public struct ChatBinderChange: Sendable, Equatable {
    public let operationIDs: [String]
    public let summary: String
    public let undo: ChatUndoReference?
    public init(operationIDs: [String], summary: String, undo: ChatUndoReference?) {
        self.operationIDs = operationIDs; self.summary = summary; self.undo = undo
    }
}
