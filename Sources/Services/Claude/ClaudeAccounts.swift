import Darwin
import Foundation
import SpravaKit

/// A name the person gives a Claude account: short, and plain enough to be what a choosing command prints.
public enum ClaudeAccountName {
    public static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._/-".unicodeScalars.contains($0) }
    }
}

/// Which Claude accounts Sprava holds a token for, and which it uses now. The tokens themselves are in the Keychain; this holds their
/// names, the day each was saved, the account in use and the person's choosing command. Sprava knows nothing of what that command runs.
final class ClaudeAccountsState: @unchecked Sendable {
    struct Token: Sendable, Equatable { let name: String; let saved: Date }
    /// The name of the token saved when Claude is first connected.
    static let mainName = "main"
    /// A subscription token lasts a year; the person is reminded a month before.
    static let tokenLife: TimeInterval = 365 * 86_400, reminder: TimeInterval = 30 * 86_400
    private let store: StateStore
    private static let schema = StateStore.Schema(version: 1, statements: [
        "CREATE TABLE tokens (name TEXT PRIMARY KEY, saved REAL NOT NULL) STRICT",
        "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT",
    ])
    init(at url: URL) throws { store = try StateStore.open(url, schema: Self.schema) }

    func tokens() throws -> [Token] {
        try store.read { t in
            try t.rows("SELECT name, saved FROM tokens ORDER BY name").compactMap { row in
                guard let name = row[0].text, let saved = row[1].real else { return nil }
                return Token(name: name, saved: Date(timeIntervalSince1970: saved))
            }
        }
    }
    func saved(_ name: String, at now: Date = Date()) throws {
        try store.write { t in try t.execute("INSERT OR REPLACE INTO tokens VALUES (?, ?)", .text(name), .real(now.timeIntervalSince1970)) }
    }
    func removed(_ name: String) throws {
        try store.write { t in
            try t.execute("DELETE FROM tokens WHERE name = ?", .text(name))
            try t.execute("DELETE FROM settings WHERE key = 'active' AND value = ?", .text(name))
        }
    }
    func clear() throws {
        try store.write { t in try t.execute("DELETE FROM tokens"); try t.execute("DELETE FROM settings") }
    }
    func setting(_ key: String) throws -> String? {
        try store.read { t in try t.rows("SELECT value FROM settings WHERE key = ?", .text(key)).first?[0].text }
    }
    func set(_ key: String, _ value: String?) throws {
        try store.write { t in
            if let value { try t.execute("INSERT OR REPLACE INTO settings VALUES (?, ?)", .text(key), .text(value)) }
            else { try t.execute("DELETE FROM settings WHERE key = ?", .text(key)) }
        }
    }
}

/// The person's command that names the account to use: outside the sandbox, set only from the app's own window, with no binder
/// data, never logged. What it prints is an account's name; exit 75 or nothing printed means no account has quota now.
enum ClaudeAccountChooser {
    enum Outcome: Sendable, Equatable { case account(String), noQuota, failed }
    static let timeout: TimeInterval = 10
    static let maximumCommandBytes = 4 * 1024

    static func run(_ command: String, shell: String = "/bin/zsh", timeout: TimeInterval = Self.timeout) -> Outcome {
        let process = Process(), out = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return .failed }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1) }
            return .failed
        }
        if process.terminationStatus == 75 { return .noQuota }
        guard process.terminationStatus == 0 else { return .failed }
        // A helper the command left behind may hold the pipe open, so this never waits for more.
        let descriptor = out.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = read(descriptor, &bytes, bytes.count)
        guard count >= 0, let text = String(bytes: bytes.prefix(count), encoding: .utf8) else { return count == -1 && errno == EAGAIN ? .noQuota : .failed }
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? .noQuota : .account(line)
    }
}
