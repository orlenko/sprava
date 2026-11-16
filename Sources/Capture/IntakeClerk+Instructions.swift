import BinderFormat
import Clerk
import Foundation
import SpravaKit

/// The clerk's card follows the person's instructions for a binder (decisions.md D43; docs/binder-instructions.md §4):
/// the folder the reader chose for the document, its attachments with it, and the name it gave the document.
extension IntakeWatcher {
    /// `ops` with every file from `intake/` moved to `doc.folder` and the first renamed to `doc.fileName`, each given a free
    /// name there again. The reader's choices were checked as it made them; a path that is not a safe document path, or a
    /// name that would make a file a key file, is checked again here and leaves the op as code built it.
    static func following(_ doc: DocumentReading, _ ops: [JSONObject], in binder: URL) -> [JSONObject] {
        guard doc.folder != nil || doc.fileName != nil else { return ops }
        var first = true
        let moved = ops.map { op -> JSONObject in
            guard op["op"] == .str("file_document"), var args = op["args"]?.objectValue, var document = args["document"]?.objectValue,
                  args["from"]?.stringValue?.hasPrefix("intake/") == true, let path = document["path"]?.stringValue, path.contains("/") else { return op }
            let main = first
            first = false
            let current = (path as NSString).lastPathComponent
            let parent = doc.folder ?? (path as NSString).deletingLastPathComponent
            let renamed = main ? doc.fileName.flatMap { DocumentPaths.isKeyFile($0) && !DocumentPaths.isKeyFile(current) ? nil : $0 } : nil
            let name = renamed ?? current
            guard DocumentPaths.isSafe(parent + "/" + name), !parent.hasPrefix("intake/"), parent != "intake" else { return op }
            document.set("path", .string(parent + "/" + name))
            if renamed != nil {
                // Kept on approval: a message's original is otherwise named again from its date and subject.
                var provenance = document["provenance"]?.objectValue ?? JSONObject()
                provenance.set("name_from", .str("instructions"))
                document.set("provenance", .object(provenance))
            }
            args.set("document", .object(document))
            var o = op
            o.set("args", .object(args))
            return o
        }
        return settlingNames(moved, in: binder)
    }

    /// The lines the card adds about the person's instructions, as intake notes: never their text.
    static func instructionsNotes(_ doc: DocumentReading) -> [String] {
        var out: [String] = []
        if doc.folder != nil { out.append("Folder from your instructions") }
        if doc.fileName != nil { out.append("File name from your instructions") }
        if let note = doc.instructionsNote { out.append(note) }
        return out
    }
}
