import Foundation
import SpravaKit

/// Places one approved draft in the binder's mail account (decisions.md D41): an `APPEND` with `\Draft` to the folder
/// the person chose, or the one the server marks as Drafts. It runs the draft worker as the intake runs its own:
/// isolated Python under the same sandbox, the password on stdin only, and the message in a private folder.
/// Sprava never sends mail; this places a draft the person sends from their own mail program.
public enum IMAPDraftAppend {
    public struct Placed: Equatable, Sendable {
        /// The folder it is in, and its UID there when the server said (`UIDPLUS`).
        public let folder: String
        public let uid: UInt32?
        /// It was there already, from an earlier attempt: nothing was appended.
        public let present: Bool
    }

    public enum Refused: Error, Equatable {
        /// The server marks no single Drafts folder and the person chose none.
        case noDraftsFolder
        case tooLarge
        case invalid
    }

    /// The largest message placed, as encoded. Attachments are at most 18 MiB before encoding (D41).
    public static let limit = 32 * 1024 * 1024

    /// Places `message`, whose `Message-ID` header is `messageID`, in the account's drafts. `directory` is a new private
    /// folder for this one attempt; the caller removes it. A retry with the same Message-ID finds the earlier draft and
    /// appends nothing.
    public static func run(_ config: BinderIMAPConnections.Configuration, password: String, folder: String?, message: Data,
                           messageID: String, directory: URL, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> Placed {
        guard message.count <= limit else { throw Refused.tooLarge }
        guard !message.isEmpty, messageID.wholeMatch(of: /<[\x21-\x3b\x3d\x3f-\x7e]{1,250}@[\x21-\x3b\x3d\x3f-\x7e]{1,250}>/) != nil,
              (folder ?? "").utf8.count <= 1024, !(folder ?? "").unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw Refused.invalid
        }
        // The interpreter is the one the connection was set up with: the exporter's pinned hash covers it.
        guard try IMAPNativeFetch.programHash() == config.programHash else { throw IMAPIntakeImport.Refused.unavailable }
        let home = try IMAPNativeFetch.physical(directory)
        guard let state = try StateDirectory.open(home) else { throw IMAPIntakeImport.Refused.unavailable }
        try state.write(message, to: "draft.eml")
        var arguments = IMAPNativeFetch.server(config.account) + ["--message-id=" + messageID]
        if let folder, !folder.isEmpty { arguments.append("--folder=" + folder) }
        let status = try IMAPNativeFetch.invoke(arguments, input: IMAPNativeFetch.credentials(config.account, password), home: home,
                                                script: IMAPDraftSource.script, name: "imap-draft.py", cancelled: cancelled)
        if status == 23 { throw Refused.noDraftsFolder }
        try IMAPNativeFetch.check(status)
        guard case .ok(let data) = SafeFile.read(home.appendingPathComponent("result.json"), limit: 8192),
              let value = try? JSONParser.parse(data).value, let placed = value["folder"]?.stringValue,
              case .bool(let present) = value["present"] ?? .null else { throw IMAPIntakeImport.Refused.unavailable }
        let uid = value["uid"]?.numberValue?.safeInteger.flatMap { $0 > 0 && $0 <= Int64(UInt32.max) ? UInt32($0) : nil }
        return Placed(folder: placed, uid: uid, present: present)
    }
}
