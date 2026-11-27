import Darwin
import Foundation
import SpravaKit

extension Adoption {
    /// Adoption reads the catalog and the history a fixed number of times, and then does work for each open item that
    /// goes over the whole catalog again: the guard judges and writes its mechanical fix, the stamp's card is checked
    /// with its closure, and saving its repair card reads the catalog for the card's fingerprints. So every open item
    /// counts as a pass, whether or not it turns out to need one, and the bound before any write is the open items times
    /// the catalog's bytes. Log entries get no op and no card, and neither does a document record that needs no fix; what
    /// is done for them is linear, and their number has a plain bound (architecture 4.6; binder-v0 9.4). A debug build
    /// takes about a second for every 10 MiB of that product when every item needs a fix, the costliest case. The fixes
    /// of document records have a budget of their own, which stops the fixes and never refuses the adoption.
    static let maxCatalogBytes = 8 << 20, maxHistoryBytes = 8 << 20, maxResumedHistoryBytes = 32 << 20
    static let maxItemWork = 128 << 20, maxRows = 20_000
    /// Document fixes times catalog bytes (`documentFixes`): some 1,400 hand-written records that all need a fix, or
    /// 500 of them in a catalog of 1 MiB.
    static let maxDocumentFixWork = 512 << 20

    static func requireBoundedWork(_ folder: URL) throws {
        let failure = TekaStore.Refused(reason: "this binder is too large or cannot be read safely for adoption; its files were left as they are")
        let data: Data
        switch SafeFile.read(folder.appendingPathComponent("catalog.json"), limit: maxCatalogBytes) {
        case .ok(let found): data = found
        case .missing: return // The ordinary reader reports a missing catalog.
        case .refused, .unreadable: throw failure
        }
        guard let catalog = try JSONParser.parse(data).value.objectValue else { throw failure }
        let items = catalog["open_items"]?.arrayValue?.count ?? 0
        let rows = ["documents", "processing_log"].reduce(items) { $0 + (catalog[$1]?.arrayValue?.count ?? 0) }
        guard items * data.count <= maxItemWork, rows <= maxRows else { throw failure }
        // SafeFile protects its final component; validate the shared parent before either descendant read.
        let directory = folder.appendingPathComponent(".sprava")
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard SafeFile.isTrustedFolder(directory) else { throw failure }
        } else if errno != ENOENT { throw failure }
        // A started adoption has added its import snapshot and fix ops to history. Reserve bounded room to
        // finish that accepted work; a regular empty marker is required, never a link or an unreadable file.
        let historyLimit: Int
        switch SafeFile.read(unfinishedMarker(folder), limit: 0) {
        case .ok: historyLimit = maxResumedHistoryBytes
        case .missing: historyLimit = maxHistoryBytes
        case .refused, .unreadable: throw failure
        }
        switch SafeFile.read(folder.appendingPathComponent(".sprava/ops.ndjson"), limit: historyLimit) {
        case .ok, .missing: break
        case .refused, .unreadable: throw failure
        }
        // Adoption also matches existing cards while resuming; bound their loading before any binder write.
        _ = try ProposalStore.boundedList(in: folder)
    }
}
