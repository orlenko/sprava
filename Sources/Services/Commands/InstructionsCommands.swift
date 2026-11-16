import BinderFormat
import BinderStore
import Foundation
import SpravaKit

/// The binder's instructions, the person's part of its `AGENTS.md` (decisions.md D43; docs/binder-instructions.md §3). The
/// app reads them itself; it saves them here, the runtime being the binder's only writer.
extension Commands {
    /// `save_instructions`: `{binder, text, expected}`, where `expected` is the digest of the person's part as the page
    /// read it. The same text confirms it as accepted. `undo_instructions`: `{binder}`, the last save taken back. Both
    /// answer `{digest}`, the part's digest now.
    func instructions(_ command: String, _ r: JSONObject) throws -> JSONObject {
        let f = try folder(r)
        let teka = Teka.read(f)
        guard teka.isAdopted else { throw Failure(message: "this binder is not adopted yet") }
        guard !teka.writesBlocked else { throw Failure(message: "this binder's writes are blocked until it is repaired; nothing was saved") }
        let digest: String
        do {
            if command == "undo_instructions" {
                digest = try BinderInstructions.undoLastSave(in: f)
            } else {
                guard case .string(let text)? = r["text"], case .string(let expected)? = r["expected"] else {
                    throw Failure(message: "text and expected are required")
                }
                digest = try BinderInstructions.save(text, expected: expected, in: f)
            }
        } catch let refused as BinderInstructions.Refused {
            throw Failure(message: refused.description)
        }
        return JSONObject([(key: "digest", value: .string(digest))])
    }
}
