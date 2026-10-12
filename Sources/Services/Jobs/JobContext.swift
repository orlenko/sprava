import BinderStore
import Foundation
import Shelf

/// What a job needs from the runtime: Sprava's support folder, the commands (absent when this Mac's device id
/// cannot be read, so nothing is written), the Shelf as a job reads it, the command queue that is the single
/// writer, the log, and the shared opaque-id lock and trust backlog. Tests pass their own.
public struct JobContext: @unchecked Sendable {
    public let support: URL
    public let commands: Commands?
    /// Set when the device id cannot be read: a job that writes reports it instead of skipping.
    public let deviceIDError: String?
    public let rows: () throws -> [ShelfRow]
    public let commandQueue: DispatchQueue?
    public let log: (String) -> Void
    public let idsLock: NSLock
    public let trustBacklog: TrustBacklog

    public init(support: URL, commands: Commands?, deviceIDError: String? = nil, rows: @escaping () throws -> [ShelfRow],
                commandQueue: DispatchQueue?, log: @escaping (String) -> Void, idsLock: NSLock = NSLock(),
                trustBacklog: TrustBacklog? = nil) {
        self.support = support
        self.commands = commands
        self.deviceIDError = deviceIDError
        self.rows = rows
        self.commandQueue = commandQueue
        self.log = log
        self.idsLock = idsLock
        self.trustBacklog = trustBacklog ?? TrustBacklog(support: support)
    }

    /// Runs `body` on the command queue, where every write to binders and to Sprava's record of cards happens.
    public func onCommandQueue<T>(_ body: () throws -> T) rethrows -> T {
        if let commandQueue { return try commandQueue.sync(execute: body) }
        return try body()
    }

    /// A job that writes, when there are no commands: an error when the device id is unreadable, else skipped.
    public var noCommands: JobOutcome {
        deviceIDError != nil ? .error(code: "device_id_unreadable", culprit: nil) : .skipped
    }

    /// Settles outside edits in each binder this Mac owns before it is read for others (architecture 4.5), and
    /// trusts the cards that writes, with any held back before (`TrustBacklog`).
    func settleOutsideEdits(_ rows: [ShelfRow], commands: Commands) -> OutsideEdits.Settled {
        let settled = OutsideEdits.settleAndTrust(rows, commands: commands, backlog: trustBacklog) { body in onCommandQueue(body) }
        if settled.cards > 0 { log("outside_edit undid_changes_cards=\(settled.cards)") }
        if settled.untrusted > 0 { log("trust_failed cards=\(settled.untrusted)") }
        return settled
    }
}

/// Waits for async work on a job's thread. Jobs run on a global queue, never on the runtime's state queue.
public func waitFor<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = WaitBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        box.value = await body()
        done.signal()
    }
    done.wait()
    return box.value!
}

final class WaitBox<T>: @unchecked Sendable { var value: T? }
