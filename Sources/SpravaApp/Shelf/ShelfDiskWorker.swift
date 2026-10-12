import Foundation

/// One disk operation at a time. A UI timeout releases its waiter, never starts another wedged worker,
/// and discards a late result; the next read is fresh once the original operation actually ends.
final class ShelfDiskWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var active = false

    init(queue: DispatchQueue) { self.queue = queue }

    func run<Value: Sendable>(timeout: TimeInterval, _ body: @escaping @Sendable () -> Value) async -> Value? {
        guard lock.withLock({ if active { return false }; active = true; return true }) else { return nil }
        return await withCheckedContinuation { continuation in
            let reply = ShelfDiskReply(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { reply.finish(nil) }
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
