import Foundation
import SpravaKit

/// Reads one message with the exact approved Message-ID in the named folder over an existing IMAP connection.
public enum IMAPDraftReadBack {
    public enum Difference: String, Codable, CaseIterable, Sendable { case recipients, subject, body, attachments }
    public enum Status: String, Codable, Sendable { case matched, missing, ambiguous, unreadable }
    public struct Result: Codable, Equatable, Sendable {
        public let status: Status
        public let differences: [Difference]
        public init(status: Status, differences: [Difference] = []) {
            self.status = status
            self.differences = differences
        }
    }

    public static func run(_ config: BinderIMAPConnections.Configuration, password: String, folder: String,
                           approved: IMAPDraftAppend.Approved, directory: URL) throws -> Result {
        guard try IMAPNativeFetch.programHash() == config.programHash, config.enabled,
              !folder.isEmpty, folder.utf8.count <= 1024, !folder.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw IMAPIntakeImport.Refused.unavailable }
        let home = try IMAPNativeFetch.physical(directory)
        guard let state = try StateDirectory.open(home) else { throw IMAPIntakeImport.Refused.unavailable }
        try state.write(try JSONEncoder().encode(approved), to: "approved.json")
        let args = IMAPNativeFetch.server(config.account) + ["--folder=" + folder]
        let status = try IMAPNativeFetch.invoke(args, input: IMAPNativeFetch.credentials(config.account, password), home: home,
                                                script: IMAPDraftReadSource.script, name: "read-draft.py", cancelled: { false })
        try IMAPNativeFetch.check(status)
        guard case .ok(let data) = try state.read("result.json", limit: 1024),
              let result = try? JSONDecoder().decode(Result.self, from: data)
        else { throw IMAPIntakeImport.Refused.unavailable }
        return result
    }
}
