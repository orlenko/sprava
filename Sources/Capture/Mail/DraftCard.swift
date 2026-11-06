import BinderFormat
import BinderStore
import Foundation
import SpravaKit

/// An email draft as a card proposes it (decisions.md D41, integrations.md §5.2): its fields only. Nothing is built or
/// sent until the person approves it; approving applies one log entry, and the message is built then (`message`).
public struct DraftCard: Sendable, Equatable {
    public struct Attachment: Sendable, Equatable {
        /// A filed document's path in the binder, as the catalog lists it.
        public var path: String
        /// The document is private: the card says so beside it.
        public var isPrivate: Bool
        public init(path: String, isPrivate: Bool) { self.path = path; self.isPrivate = isPrivate }
    }

    public var to: [String]
    public var cc: [String]
    public var subject: String
    public var body: String
    public var attachments: [Attachment]
    public var inReplyTo: String?
    public var references: [String]

    public enum Refused: Error, Equatable {
        /// A field the message cannot carry, by name; never its value.
        case field(String)
        /// An attachment that is not a document filed in this binder, by its index.
        case attachment(Int)
        case tooLarge
    }

    static let maxRecipients = 50, maxBody = 100_000, maxAttachments = 20
    /// Where the draft's own Message-ID points; a retry finds the draft by it.
    static let idDomain = "drafts.sprava.invalid"

    public init(to: [String], cc: [String] = [], subject: String, body: String, attachments: [Attachment] = [],
                inReplyTo: String? = nil, references: [String] = []) {
        self.to = to; self.cc = cc; self.subject = subject; self.body = body; self.attachments = attachments
        self.inReplyTo = inReplyTo; self.references = references
    }

    /// The card's fields, when this proposal is a draft card Sprava wrote.
    public init?(_ proposal: Proposal) {
        guard let d = proposal.raw["provenance"]?["draft"] else { return nil }
        func strings(_ key: String) -> [String]? { d[key]?.arrayValue.map { $0.compactMap(\.stringValue) } }
        guard let to = strings("to"), let subject = d["subject"]?.stringValue, let body = d["body"]?.stringValue else { return nil }
        let attachments = (d["attachments"]?.arrayValue ?? []).compactMap { a -> Attachment? in
            guard let path = a["path"]?.stringValue else { return nil }
            return Attachment(path: path, isPrivate: a["private"] == .bool(true))
        }
        self.init(to: to, cc: strings("cc") ?? [], subject: subject, body: body, attachments: attachments,
                  inReplyTo: d["in_reply_to"]?.stringValue, references: strings("references") ?? [])
    }

    /// The draft's Message-ID, made from its card's id, so a retry after approval finds the same draft.
    public static func messageID(card id: String) -> String { "<draft-\(id)@\(idDomain)>" }

    /// Checks the fields as the message will (`MailDraft`), and each attachment against `catalog`: it must be a document
    /// filed in this binder. The card marks the private ones. A refusal names the field, never its value.
    public func checked(catalog: JSONObject?) throws -> DraftCard {
        guard !to.isEmpty, to.count + cc.count <= Self.maxRecipients else { throw Refused.field("To") }
        guard body.count <= Self.maxBody else { throw Refused.field("Body") }
        guard attachments.count <= Self.maxAttachments else { throw Refused.field("Attachments") }
        do {
            _ = try MailDraft(from: .init(address: "check@\(Self.idDomain)"), to: to.map { .init(address: $0) }, cc: cc.map { .init(address: $0) },
                              subject: subject, body: body, inReplyTo: inReplyTo, references: references,
                              messageID: Self.messageID(card: "check"), date: Date(timeIntervalSince1970: 0))
        } catch let failure as MailDraft.Failure {
            throw Refused.field(Self.name(of: failure))
        }
        let filed = catalog?["documents"]?.arrayValue ?? []
        var marked = self
        for (index, attachment) in attachments.enumerated() {
            // A key or credential file is never read, whatever names it (binder-v0 §3.3).
            guard DocumentPaths.isSafe(attachment.path), !DocumentPaths.isKeyFile(attachment.path),
                  let doc = filed.first(where: { $0["path"]?.stringValue == attachment.path }) else {
                throw Refused.attachment(index)
            }
            marked.attachments[index].isPrivate = doc["sensitivity"] == .str("private")
        }
        return marked
    }

    /// The card: one op, a log entry that names the recipients and subject but never the body, and the fields in its
    /// provenance. `checked` first; the caller writes it to the binder's cards.
    public func proposal(actor: JSONObject, catalog: JSONObject?, now: Date = Date()) throws -> Proposal {
        let card = try checked(catalog: catalog)
        let entry = JSONObject([(key: "action", value: .string("Email draft to \(card.to.joined(separator: ", ")): \(card.subject)"))])
        let op = JSONObject([(key: "op", value: .str("add_log_entry")), (key: "args", value: .obj([("entry", .object(entry))]))])
        var draft = JSONObject([(key: "to", value: .array(card.to.map(JSONValue.string))), (key: "cc", value: .array(card.cc.map(JSONValue.string))),
                                (key: "subject", value: .string(card.subject)), (key: "body", value: .string(card.body)),
                                (key: "attachments", value: .array(card.attachments.map {
                                    .obj([("path", .string($0.path)), ("private", .bool($0.isPrivate))]) }))])
        if let inReplyTo = card.inReplyTo { draft.set("in_reply_to", .string(inReplyTo)) }
        if !card.references.isEmpty { draft.set("references", .array(card.references.map(JSONValue.string))) }
        return Proposal.make(title: "Email draft: \(card.subject)", actor: actor, ops: [op],
                             provenance: JSONObject([(key: "draft", value: .object(draft))]), now: now)
    }

    /// The message, built at approval: from `from`, its attachments read now from the binder's filed documents, from the
    /// binder down with no link anywhere on the way, at most 18 MiB together. What is placed is exactly this.
    public func message(card id: String, from: String, folder: URL, catalog: JSONObject?, now: Date = Date()) throws -> Data {
        let card = try checked(catalog: catalog)
        var files: [MailDraft.Attachment] = []
        var total = 0
        for (index, attachment) in card.attachments.enumerated() {
            let limit = MailDraft.Limits().attachmentBytes
            let data: Data
            switch SafeFile.read(folder.appendingPathComponent(attachment.path), under: folder, limit: limit - total) {
            case .ok(let read): data = read
            case .refused(let why) where why.hasPrefix("larger than"): throw Refused.tooLarge
            default: throw Refused.attachment(index)   // gone, a link, not a plain file, or not the person's
            }
            total += data.count
            files.append(.init(filename: (attachment.path as NSString).lastPathComponent, data: data))
        }
        do {
            return try MailDraft(from: .init(address: from), to: card.to.map { .init(address: $0) }, cc: card.cc.map { .init(address: $0) },
                                 subject: card.subject, body: card.body, attachments: files, inReplyTo: card.inReplyTo,
                                 references: card.references, messageID: Self.messageID(card: id), date: now).rfc822
        } catch MailDraft.Failure.overLimit {
            throw Refused.tooLarge
        } catch let failure as MailDraft.Failure {
            throw Refused.field(Self.name(of: failure))
        }
    }

    static func name(of failure: MailDraft.Failure) -> String {
        switch failure {
        case .address(let field), .headerText(let field), .messageID(let field): field
        case .filename: "Attachments"
        case .overLimit: "Attachments"
        case .boundary: "Body"
        }
    }
}
