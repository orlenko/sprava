import Foundation

/// UUID version 7: time-ordered, as the op log and capture events use (binder-v0 §6.2). Ids made by one process
/// are strictly increasing even within one millisecond: the 12 `rand_a` bits carry a counter (RFC 9562 §6.2,
/// method 1), so files named by these ids list in creation order.
public enum UUIDv7 {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastMS: UInt64 = 0
    nonisolated(unsafe) private static var counter: UInt64 = 0

    public static func make(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)   // the kernel generator; unlike SecRandomCopyBytes it cannot fail
        var ms = UInt64(max(0, now.timeIntervalSince1970) * 1000)
        lock.lock()
        if ms <= lastMS {
            ms = lastMS
            counter += 1
            if counter > 0xFFF { ms += 1; counter = 0 }
        } else {
            counter = 0
        }
        lastMS = ms
        let seq = counter
        lock.unlock()
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xFF) }
        bytes[6] = 0x70 | UInt8((seq >> 8) & 0x0F)
        bytes[7] = UInt8(seq & 0xFF)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }
}
