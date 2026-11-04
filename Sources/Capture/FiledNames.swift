import BinderFormat
import Foundation
import SpravaKit

/// The names documents are filed under. A name is settled when a card is written and again when it is approved: other
/// cards may have filed since, and many messages' originals share one machine-made name, so a card's name never
/// stops a filing. Nothing is ever overwritten; a taken name gets a number.
extension IntakeWatcher {
    /// What a mail monitor calls the original of every message, in that message's attachments folder.
    package static let mailOriginalName = "000-original-message.eml"

    /// `ops` with each file coming from `intake/` given a free path in the folder it already names.
    package static func settlingNames(_ ops: [JSONObject], in binder: URL) -> [JSONObject] {
        var used = Set<String>()
        var message: String?
        return ops.map { op in
            guard op["op"] == .str("file_document"), var args = op["args"]?.objectValue, var document = args["document"]?.objectValue,
                  let from = args["from"]?.stringValue, let path = document["path"]?.stringValue, path.contains("/") else { return op }
            let folder = (path as NSString).deletingLastPathComponent
            let wanted = readableName(document, path: path, from: from, message: message)
            var settled = freePath(folder, wanted, in: binder)
            var n = 2
            let stem = (wanted as NSString).deletingPathExtension, ext = (wanted as NSString).pathExtension
            while used.contains(DocumentPaths.fold(settled)) && n < 1000 {
                settled = freePath(folder, "\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"), in: binder)
                n += 1
            }
            used.insert(DocumentPaths.fold(settled))
            if message == nil, from.hasPrefix("intake/mail/") {
                message = ((settled as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            document.set("path", .string(settled))
            args.set("document", .object(document))
            var changed = op
            changed.set("args", .object(args))
            return changed
        }
    }

    /// The name a person would want. A message's original goes by the name of its message, and a message named by a
    /// machine (`imap-<id>-<validity>-<uid>`) goes by its date and subject. Any other file keeps its own name.
    private static func readableName(_ document: JSONObject, path: String, from: String, message: String?) -> String {
        let current = (path as NSString).lastPathComponent
        let source = (from as NSString).lastPathComponent
        guard from.hasPrefix("intake/mail/") else { return current }
        let proposed: String
        if source == mailOriginalName, let message {
            proposed = message + ".eml"
        } else if source.hasPrefix("imap-") {
            let stem = (source as NSString).deletingPathExtension
            let title = document["title"]?.stringValue.flatMap { $0 == stem ? nil : $0 } ?? "email"
            let date = document["date"]?.stringValue.map { $0 + " " } ?? ""
            proposed = shortened(date + title.replacingOccurrences(of: ":", with: " -")) + "." + (source as NSString).pathExtension
        } else {
            return current
        }
        let name = DocumentPaths.safeName(proposed)
        let parent = (path as NSString).deletingLastPathComponent
        return DocumentPaths.isKeyFile(name) || !DocumentPaths.isSafe(parent + "/" + name) ? current : name
    }

    /// A subject may be longer in bytes than a file name can be; room is left for a number and an extension.
    private static func shortened(_ stem: String) -> String {
        var out = stem
        while out.utf8.count > 200 { out.removeLast() }
        return out.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    }
}
