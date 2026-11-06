import BinderStore
import Foundation
import SpravaKit

/// The email draft cards Sprava itself wrote (decisions.md D41), by binder and card id, in `capture/draft-cards.json`.
/// Only these are approved as drafts: a card that holds a draft but came another way never exports anything.
struct DraftCardRecord {
    let file: URL
    init(support: URL) { file = support.appendingPathComponent("capture/draft-cards.json") }

    func contains(_ key: String) -> Bool { keys().contains(key) }

    func record(_ key: String) throws {
        var all = keys()
        guard !all.contains(key) else { return }
        all.append(key)
        // The newest thousand: an older card that was never approved is not offered again.
        let kept = Array(all.suffix(1000))
        try AtomicFile.makePrivateFolder(file.deletingLastPathComponent())
        try AtomicFile.write(Data(JSONWriter.compact(.array(kept.map(JSONValue.string))).utf8), to: file)
    }

    private func keys() -> [String] {
        guard case .ok(let data) = SafeFile.read(file, limit: 1 << 20), let value = try? JSONParser.parse(data).value else { return [] }
        return value.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

extension Commands {
    /// Records a draft card Sprava wrote, so it can be approved as one. Its writer calls this with the card's digest.
    public func recordDraftCard(_ id: String, in folder: URL) throws {
        try DraftCardRecord(support: support).record(key(folder, id))
    }
}
