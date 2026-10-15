import Foundation

public struct CompanionOwnerConfiguration: Sendable, Equatable {
    public let origin: String
    public let instance: String
    public let webOrigin: String?
}

extension CompanionProfile {
    /// Read the committed public setup binding without loading any credential (§6).
    public func ownerConfiguration() throws -> CompanionOwnerConfiguration? {
        guard try store.read({ try epoch($0) }) != nil else { return nil }
        return CompanionOwnerConfiguration(origin: relay.origin, instance: relay.instance, webOrigin: try webOrigin())
    }
}

/// companion-v0 §5.1: all link material stays in the fragment, never a query sent to either server.
/// Resolve the configured or shared-build web origin before calling. The returned secret is for the QR UI only.
public enum CompanionPairingLink {
    public static func make(webOrigin: String, relay: CompanionRelayIdentity, start: CompanionPairingStart) throws -> String {
        guard CompanionRelayIdentity.validOrigin(webOrigin), CompanionWire.isID(start.created.id),
              CompanionWire.isID(start.created.secret), CompanionWire.isID(start.deviceID),
              start.ownerPublicKey.count == 32 else { throw CompanionOwnerPairingError.invalid }
        let fields = [CompanionWire.base64(Data(relay.origin.utf8)), start.created.id, start.created.secret,
                      CompanionWire.base64(start.ownerPublicKey), start.deviceID]
        return webOrigin + "/#pair=v0." + fields.joined(separator: ".")
    }
}
