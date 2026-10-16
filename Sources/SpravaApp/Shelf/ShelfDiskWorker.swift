import Foundation

/// Starts the bound of one disk operation: calls `expire` once `timeout` seconds have passed. Tests pass one they
/// expire by hand, so a read is late only when the test makes it late.
typealias DiskDeadline = @Sendable (_ timeout: TimeInterval, _ expire: @escaping @Sendable () -> Void) -> Void

/// One disk operation at a time. A UI timeout releases its waiter, never starts another wedged worker,
/// and discards a late result; the next read is fresh once the original operation actually ends.
final class ShelfDiskWorker: @unchecked Sendable {
    static let wallClock: DiskDeadline = { timeout, expire in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: expire)
    }

    private let queue: DispatchQueue
    private let deadline: DiskDeadline
    private let lock = NSLock()
    private var active = false

    init(queue: DispatchQueue, deadline: @escaping DiskDeadline = ShelfDiskWorker.wallClock) {
        self.queue = queue
        self.deadline = deadline
    }

    func run<Value: Sendable>(timeout: TimeInterval, _ body: @escaping @Sendable () -> Value) async -> Value? {
        guard lock.withLock({ if active { return false }; active = true; return true }) else { return nil }
        return await withCheckedContinuation { continuation in
            let reply = ShelfDiskReply(continuation)
            deadline(timeout) { reply.finish(nil) }
            queue.async { [self] in
                let value = body()
                lock.withLock { active = false }
                reply.finish(value)
            }
        }
    }
}

private final class ShelfDiskReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }

    func finish(_ value: Value?) {
        let reply = lock.withLock {
            let reply = continuation
            continuation = nil
            return reply
        }
        reply?.resume(returning: value)
    }
}
