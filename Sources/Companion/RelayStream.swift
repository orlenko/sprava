import Foundation

public enum CompanionRelayError: Error, Equatable { case invalid }
public struct CompanionRelayReply<Value: Sendable>: Sendable {
    public let status: Int
    public let value: Value?
    /// Bytes received, including an error body that is deliberately not exposed to callers.
    public let receivedBytes: Int
    init(status: Int, value: Value?, receivedBytes: Int = 0) {
        self.status = status; self.value = value; self.receivedBytes = receivedBytes
    }
}

/// companion-v0 §3.2: count while receiving, before holding a response whole. One private session per call.
final class RelayStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let successLimit: Int
    private let errorLimit: Int
    private var maximum = 4096
    private var bytes = Data()
    private var status: Int?
    private var finished = false
    private var continuation: CheckedContinuation<CompanionRelayReply<Data>, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timeout: Task<Void, Never>?
    init(limit: Int, downloadLimit: Int? = nil) {
        successLimit = min(limit, downloadLimit ?? limit)
        errorLimit = min(4096, downloadLimit ?? 4096)
    }

    func send(_ request: URLRequest, configuration: URLSessionConfiguration,
              deadline: Duration = .seconds(30)) async throws -> CompanionRelayReply<Data> {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if finished {
                    lock.unlock(); continuation.resume(throwing: CompanionRelayError.invalid); return
                }
                self.continuation = continuation
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                self.session = session; self.task = task
                timeout = Task {
                    do { try await Task.sleep(for: deadline) } catch { return }
                    self.finish(.failure(CompanionRelayError.invalid))
                }
                lock.unlock(); task.resume()
            }
        } onCancel: { self.finish(.failure(CompanionRelayError.invalid)) }
    }

    private func finish(_ result: Result<CompanionRelayReply<Data>, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation, session = session, task = task, timeout = timeout
        self.continuation = nil; self.session = nil; self.task = nil; self.timeout = nil; bytes.removeAll()
        lock.unlock()
        timeout?.cancel(); task?.cancel(); session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Neither the token nor a secret claim body can follow a Location supplied by the relay.
        completionHandler(nil); finish(.failure(CompanionRelayError.invalid))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200...599).contains(response.statusCode),
              !(300...399).contains(response.statusCode) else {
            completionHandler(.cancel); finish(.failure(CompanionRelayError.invalid)); return
        }
        let bound = (200...299).contains(response.statusCode) ? successLimit : errorLimit
        guard response.expectedContentLength <= bound else {
            completionHandler(.cancel); finish(.failure(CompanionRelayError.invalid)); return
        }
        lock.lock(); status = response.statusCode; maximum = bound; let stopped = finished; lock.unlock()
        completionHandler(stopped ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= maximum - bytes.count else {
            lock.unlock(); finish(.failure(CompanionRelayError.invalid)); return
        }
        bytes.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let reply = status.map { CompanionRelayReply(status: $0, value: (200...299).contains($0) ? bytes : nil, receivedBytes: bytes.count) }
        lock.unlock()
        if error != nil || reply == nil { finish(.failure(CompanionRelayError.invalid)) }
        else { finish(.success(reply!)) }
    }
}
