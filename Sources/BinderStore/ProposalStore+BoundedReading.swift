import Darwin
import Foundation
import SpravaKit

extension ProposalStore {
    /// A display read with a bound on directory entries and on aggregate file bytes, enforced before parsing and
    /// retaining cards (architecture 4.6). Refusal preserves every file and reports that the collection needs care.
    public static func boundedList(in folder: URL, maxEntries: Int = 100, maxBytes: Int = 8 << 20) throws -> [(Proposal, String)] {
        let failure = TekaStore.Refused(reason: "the proposal collection is too large or cannot be read safely; its files were left as they are")
        guard maxEntries >= 0, maxBytes >= 0 else { throw failure }
        var info = stat()
        if lstat(dir(folder).path, &info) != 0, errno == ENOENT { return [] }
        let directory = try checkedDir(folder, create: false)
        var failed = false
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                           options: .skipsSubdirectoryDescendants,
                                                           errorHandler: { _, _ in failed = true; return false }) else { throw failure }
        var count = 0, bytes = 0
        var cards: [(Proposal, String)] = []
        for case let file as URL in entries {
            guard count < maxEntries else { throw failure }
            count += 1
            let name = file.lastPathComponent
            guard name.hasSuffix(".json"), isValidID(String(name.dropLast(5))) else { continue }
            guard case .ok(let data) = SafeFile.read(file, limit: maxBytes - bytes) else { throw failure }
            bytes += data.count
            guard case .object(let raw) = try JSONParser.parse(data).value,
                  raw["id"]?.stringValue == String(name.dropLast(5)) else { throw failure }
            cards.append((Proposal(raw: raw), digest(data)))
        }
        guard !failed else { throw failure }
        return cards.sorted { $0.0.id < $1.0.id }
    }
}
