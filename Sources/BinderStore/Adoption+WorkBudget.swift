import Darwin
import Foundation
import SpravaKit

extension Adoption {
    /// Mechanical adoption rereads the catalog and history for each item. Keep it off beyond this budget until
    /// the writer can process all items in a fixed number of passes (architecture 4.6; binder-v0 9.4).
    static func requireBoundedWork(_ folder: URL) throws {
        let failure = TekaStore.Refused(reason: "this binder is too large or cannot be read safely for adoption; its files were left as they are")
        let data: Data
        switch SafeFile.read(folder.appendingPathComponent("catalog.json"), limit: 1 << 20) {
        case .ok(let found): data = found
        case .missing: return // The ordinary reader reports a missing catalog.
        case .refused, .unreadable: throw failure
        }
        guard let catalog = try JSONParser.parse(data).value.objectValue else { throw failure }
        let rows = ["open_items", "documents", "processing_log"].reduce(0) { $0 + (catalog[$1]?.arrayValue?.count ?? 0) }
        guard rows <= 100 else { throw failure }
        // SafeFile protects its final component; validate the shared parent before either descendant read.
        let directory = folder.appendingPathComponent(".sprava")
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard SafeFile.isTrustedFolder(directory) else { throw failure }
        } else if errno != ENOENT { throw failure }
        // A started adoption has added its import snapshot and fix ops to history. Reserve bounded room to
        // finish that accepted work; a regular empty marker is required, never a link or an unreadable file.
        let workLimit: Int
        switch SafeFile.read(unfinishedMarker(folder), limit: 0) {
        case .ok: workLimit = 32 << 20
        case .missing: workLimit = 4 << 20
        case .refused, .unreadable: throw failure
        }
        let perPass = workLimit / max(1, rows)
        guard data.count <= perPass else { throw failure }
        switch SafeFile.read(folder.appendingPathComponent(".sprava/ops.ndjson"), limit: perPass - data.count) {
        case .ok, .missing: break
        case .refused, .unreadable: throw failure
        }
        // Adoption also matches existing cards while resuming; bound their loading before any binder write.
        _ = try ProposalStore.boundedList(in: folder)
    }
}
