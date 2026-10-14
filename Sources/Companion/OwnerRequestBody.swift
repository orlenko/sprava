import Foundation

public enum CompanionRequestDownload: Sendable {
    case body(Data), tooLarge
}
extension CompanionOwnerRelay {
    /// companion-v0 §§3.2, 9.3: oversized bodies are discardable; partial downloads or spent budgets stop the drain.
    /// Subtract receivedBytes, including errors; 404 is only a lost candidate until the drain's second fetch.
    public func fetchRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestDownload> {
        guard CompanionWire.isID(deviceID), CompanionWire.isID(requestID) else { throw CompanionRelayError.invalid }
        do {
            let reply = try await call("/v0/requests/" + deviceID + "/" + requestID, limit: 65536,
                downloadLimit: downloadLimit, discardOversizedRequest: true)
            guard reply.status == 200, let bytes = reply.value else {
                return CompanionRelayReply(status: reply.status, value: nil, receivedBytes: reply.receivedBytes)
            }
            return CompanionRelayReply(status: 200, value: .body(bytes), receivedBytes: reply.receivedBytes)
        } catch CompanionRelayError.requestTooLarge(let receivedBytes) {
            return CompanionRelayReply(status: 200, value: .tooLarge, receivedBytes: receivedBytes)
        }
    }
}
