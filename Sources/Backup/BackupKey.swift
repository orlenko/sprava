import Foundation

/// Backup recovery keys (docs/backup.md §4): 30 base32 characters, grouped for typing.
public enum BackupKey {
    /// Uses the system random source directly; an unnoticed failure must never produce an all-zero key.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 30)
        arc4random_buf(&bytes, bytes.count)
        return format(bytes)
    }

    static func format(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 30)
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: 30, by: 5).map { String(chars[$0..<($0 + 5)]) }.joined(separator: "-")
    }

    /// Typed keys are compared without case, spaces or dashes.
    public static func normalize(_ typed: String) -> String {
        typed.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
