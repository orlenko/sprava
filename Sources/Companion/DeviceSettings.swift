import Foundation
import SpravaKit

public struct CompanionPairedDevice: Sendable, Equatable {
    public enum Confirmation: String, Sendable { case awaiting, acknowledged, notConfirmed = "not-confirmed" }
    public let deviceID: String
    /// Private display text from the validated hello; never include it in logs or the heartbeat.
    public let label: String
    public let pairedAt: String
    public let confirmation: Confirmation
}
public struct CompanionPairedDevicePage: Sendable {
    public let devices: [CompanionPairedDevice]
    public let next: String?
}

extension CompanionProfile {
    /// companion-v0 §5.2 steps 4, 6: local labels and acknowledgment status, even when the relay or keys are unavailable.
    /// Only active local devices are listed. Reading this snapshot performs no network, key or cleanup work.
    public func pairedDevices(now: String, limit: Int = 20, after: String? = nil) throws -> CompanionPairedDevicePage {
        guard CompanionOwnerRelay.time(now), (1...20).contains(limit) else {
            throw CompanionOwnerPairingError.invalid
        }
        if let after, !CompanionWire.isID(after) { throw CompanionOwnerPairingError.invalid }
        return try store.read { t in
            let rows = try t.rows("""
                SELECT d.device, p.label, p.paired_at, p.acknowledged, COALESCE(d.local_deadline, p.expires)
                FROM devices d LEFT JOIN pairings p ON p.device = d.device
                WHERE d.state = 'active' AND d.device > ? ORDER BY d.device LIMIT ?
                """, .text(after ?? ""), .integer(Int64(limit + 1)))
            let devices = try rows.prefix(limit).map { row -> CompanionPairedDevice in
                guard row.count == 5, let id = row[0].text, CompanionWire.isID(id), let label = row[1].text,
                      (1...40).contains(label.unicodeScalars.count), JSONWriter.compact(.string(label)).utf8.count - 2 <= 160,
                      label.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
                      let paired = row[2].text, CompanionOwnerRelay.time(paired),
                      let acknowledged = row[3].integer, (0...1).contains(acknowledged),
                      let deadline = row[4].text, CompanionOwnerRelay.time(deadline) else {
                    throw CompanionOwnerPairingError.invalid
                }
                let confirmation: CompanionPairedDevice.Confirmation = acknowledged == 1 ? .acknowledged :
                    (now >= deadline ? .notConfirmed : .awaiting)
                return CompanionPairedDevice(deviceID: id, label: label, pairedAt: paired, confirmation: confirmation)
            }
            return CompanionPairedDevicePage(devices: devices, next: rows.count > limit ? devices.last?.deviceID : nil)
        }
    }
}
