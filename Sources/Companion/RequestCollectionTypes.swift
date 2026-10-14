import Foundation

public struct CompanionCollectionAllowance: Sendable {
    public let downloadBytes: Int
    public let fetches: Int
    public let checkedRequests: Int
    public init(downloadBytes: Int = 8388608, fetches: Int = 100, checkedRequests: Int = 100) throws {
        guard (0...8388608).contains(downloadBytes), (0...100).contains(fetches), (0...100).contains(checkedRequests) else { throw CompanionRelayError.invalid }
        self.downloadBytes = downloadBytes; self.fetches = fetches; self.checkedRequests = checkedRequests
    }
}
public struct CompanionCollectionFailure: Sendable {
    /// Nil for an invalid id: never expose rejected relay text in diagnostics.
    public let requestID: String?
    public let reason: CompanionRequestAdmission.Discard
}
public struct CompanionCollectedRequests: Sendable {
    public enum Stop: Sendable { case complete, budget, inactive, pendingDecision, dailyCap }
    public let requests: [CompanionAuthenticatedRequest]
    public let failures: [CompanionCollectionFailure]
    /// Counts include malformed listing metadata; failures is only the last 100 entries.
    public let discardedCounts: [CompanionRequestAdmission.Discard: Int]
    public let duplicates: Int
    public let lost: Int
    public let downloadedBytes: Int
    public let fetches: Int
    public let checkedRequests: Int
    public let stop: Stop
}
protocol RequestCollectionTransport: Sendable {
    func listRequests(deviceID: String, after: Int64?, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestPage>
    func fetchRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestDownload>
    func deleteRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<Data>
}
extension CompanionOwnerRelay: RequestCollectionTransport {}
