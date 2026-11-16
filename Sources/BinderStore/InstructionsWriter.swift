import BinderFormat
import Foundation
import SpravaKit

/// Saves the person's part of a binder's `AGENTS.md` (decisions.md D43; docs/binder-instructions.md §3): only over the
/// text the page read, keeping Sprava's section as found, in one atomic write, after keeping the file it replaces for one
/// Undo. The saved text is recorded as accepted, so the reader of new documents follows it. The runtime is the only caller.
extension BinderInstructions {
    /// Why nothing was written: each a plain sentence for the page.
    public enum Refused: Error, Equatable, CustomStringConvertible {
        case changed
        case tooLong
        case nothingToUndo
        case notAdopted
        case file(Problem)

        public var description: String {
            switch self {
            case .changed: "AGENTS.md changed since this page read it, so nothing was saved. Your text is still here: copy it, then Reload."
            case .tooLong: "Instructions are at most \(BinderInstructions.maxCharacters) characters. Shorten them to save."
            case .nothingToUndo: "There is no save to undo: AGENTS.md changed since the last save, or it was undone already."
            case .notAdopted: "This binder has no .sprava folder, so its instructions cannot be saved here."
            case .file(let problem): problem.description
            }
        }
    }

    /// Writes `text` as the person's part when the part on disk still has the digest `expected`, and records it as
    /// accepted. Saving the same text writes only the acceptance, so an empty text where there is no file makes none. The
    /// file is never deleted: an empty text saves an empty part. Returns the digest now on disk.
    @discardableResult
    public static func save(_ text: String, expected: String, in folder: URL) throws -> String {
        guard fits(text) else { throw Refused.tooLong }
        let found = try current(folder)
        guard found.digest == expected else { throw Refused.changed }
        let state = try stateDirectory(folder)
        let after = digest(text)
        guard found.text != text else {
            try writeRecord(state, accepted: after, undoAfter: found.undoAfter, previousAccepted: previousAccepted(folder))
            return after
        }
        // The file as it was, whole, before anything changes: a crash after this leaves the old file in place.
        let agents = folder.appendingPathComponent(fileName)
        let before: Data
        switch SafeFile.read(agents, under: folder, limit: fileLimit) {
        case .ok(let data): before = data
        case .missing: before = Data()
        case .refused(let why): throw Refused.file(.refused(why))
        case .unreadable(let why): throw Refused.file(.unreadable(why))
        }
        try state.write(before, to: (previousPath as NSString).lastPathComponent)
        try AtomicFile.write(Data(found.contents(with: text).utf8), to: agents, mode: 0o644)
        try writeRecord(state, accepted: after, undoAfter: after, previousAccepted: found.isAccepted)
        return after
    }

    /// Puts back the person's part the last save replaced, under the current Sprava section, while the part is still as
    /// that save left it. No size bound: the replaced text may be a long old manual the person just trimmed. It is
    /// accepted only if it was before that save. One level: the record of the save is cleared.
    @discardableResult
    public static func undoLastSave(in folder: URL) throws -> String {
        let found = try current(folder)
        guard found.canUndo else { throw Refused.nothingToUndo }
        let state = try stateDirectory(folder)
        let previous: String
        switch try state.read((previousPath as NSString).lastPathComponent, limit: fileLimit) {
        case .ok(let data):
            guard let contents = String(data: data, encoding: .utf8) else { throw Refused.file(.notText) }
            switch parse(contents) {
            case .success(let parsed): previous = parsed.text
            case .failure(let problem): throw Refused.file(problem)
            }
        case .missing: throw Refused.nothingToUndo
        case .refused(let why): throw Refused.file(.refused(why))
        case .unreadable(let why): throw Refused.file(.unreadable(why))
        }
        try AtomicFile.write(Data(found.contents(with: previous).utf8), to: folder.appendingPathComponent(fileName), mode: 0o644)
        let after = digest(previous)
        try writeRecord(state, accepted: previousAccepted(folder) ? after : nil, undoAfter: nil, previousAccepted: false)
        return after
    }

    static func current(_ folder: URL) throws -> BinderInstructions {
        switch read(folder) {
        case .success(let read): return read
        case .failure(let problem): throw Refused.file(problem)
        }
    }

    static func stateDirectory(_ folder: URL) throws -> StateDirectory {
        guard let state = try StateDirectory.open(folder.appendingPathComponent(".sprava")) else { throw Refused.notAdopted }
        return state
    }

    /// Whether the text the last save replaced had been accepted; false when unknown.
    static func previousAccepted(_ folder: URL) -> Bool {
        guard case .ok(let data) = SafeFile.read(folder.appendingPathComponent(recordPath), under: folder, limit: 64 * 1024),
              let value = try? JSONParser.parse(data).value else { return false }
        return value["previous_accepted"] == .bool(true)
    }

    static func writeRecord(_ state: StateDirectory, accepted: String?, undoAfter: String?, previousAccepted: Bool) throws {
        let record = JSONValue.obj([("accepted", accepted.map(JSONValue.string) ?? .null),
                                    ("undo_after", undoAfter.map(JSONValue.string) ?? .null),
                                    ("previous_accepted", .bool(previousAccepted))])
        try state.write(Data(JSONWriter.pretty(record).utf8), to: (recordPath as NSString).lastPathComponent)
    }
}
