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
        case markersInText
        case file(Problem)

        public var description: String {
            switch self {
            case .changed: "AGENTS.md changed since this page read it, so nothing was saved. Your text is still here: copy it, then Reload."
            case .tooLong: "Instructions are at most \(BinderInstructions.maxCharacters) characters. Shorten them to save."
            case .nothingToUndo: "There is no save to undo: AGENTS.md changed since the last save, or it was undone already."
            case .notAdopted: "This binder has no .sprava folder, so its instructions cannot be saved here."
            case .markersInText: "Your text holds a line Sprava keeps for its own part of AGENTS.md (\(BinderInstructions.begin) or \(BinderInstructions.end)). Remove it to save."
            case .file(let problem): problem.description
            }
        }
    }

    /// The two files a save's backup alternates between: a save writes the one the record does not name, so a save cut
    /// short never overwrites the backup the record still offers for Undo.
    static let slots = [(previousPath as NSString).lastPathComponent, "instructions-previous-2.md"]

    /// Writes `text` as the person's part when the part on disk still has the digest `expected`, and records it as
    /// accepted. Saving the same text writes only the acceptance, so an empty text where there is no file makes none. The
    /// file is never deleted: an empty text saves an empty part. Returns the digest now on disk.
    @discardableResult
    public static func save(_ text: String, expected: String, in folder: URL) throws -> String {
        guard fits(text) else { throw Refused.tooLong }
        // Marker lines of Sprava's own in the text would make a file that no longer reads.
        guard case .success(let own) = parse(text), own.section.isEmpty else { throw Refused.markersInText }
        let found = try current(folder)
        guard found.digest == expected else { throw Refused.changed }
        let state = try stateDirectory(folder)
        let record = Record(folder)
        let after = digest(text)
        guard found.text != text else {
            try record.with(accepted: after).write(state)
            return after
        }
        // The file as it was, whole, into the slot the record does not name, before anything else changes.
        let agents = folder.appendingPathComponent(fileName)
        let before: Data
        switch SafeFile.read(agents, under: folder, limit: fileLimit) {
        case .ok(let data): before = data
        case .missing: before = Data()
        case .refused(let why): throw Refused.file(.refused(why))
        case .unreadable(let why): throw Refused.file(.unreadable(why))
        }
        let slot = record.slot == slots[0] ? slots[1] : slots[0]
        try state.write(before, to: slot)
        try write(found.contents(with: text), section: found.section, text: text, to: agents)
        try Record(accepted: after, undoAfter: after, slot: slot, previousAccepted: found.isAccepted).write(state)
        return after
    }

    /// Writes a new binder's first instructions, from the template the person chose (docs/binder-instructions.md §5), and
    /// records them as accepted, since the person saw them in the preview. Only where there is no `AGENTS.md` yet; no Undo.
    public static func start(_ text: String, in folder: URL) throws {
        guard fits(text) else { throw Refused.tooLong }
        guard case .success(let own) = parse(text), own.section.isEmpty else { throw Refused.markersInText }
        guard try !current(folder).exists else { throw Refused.changed }
        let state = try stateDirectory(folder)
        try write(text, section: "", text: text, to: folder.appendingPathComponent(fileName))
        try Record(accepted: digest(text), undoAfter: nil, slot: nil, previousAccepted: false).write(state)
    }

    /// Puts back the person's part the last save replaced, under the current Sprava section, while the part is still as
    /// that save left it. No size bound: the replaced text may be a long old manual the person just trimmed. It is
    /// accepted only if it was before that save. One level: the record of the save is cleared.
    @discardableResult
    public static func undoLastSave(in folder: URL) throws -> String {
        let found = try current(folder)
        guard found.canUndo else { throw Refused.nothingToUndo }
        let state = try stateDirectory(folder)
        let record = Record(folder)
        guard let slot = record.slot, slots.contains(slot) else { throw Refused.nothingToUndo }
        let previous: String
        switch try state.read(slot, limit: fileLimit) {
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
        try write(found.contents(with: previous), section: found.section, text: previous, to: folder.appendingPathComponent(fileName))
        let after = digest(previous)
        try Record(accepted: record.previousAccepted ? after : nil, undoAfter: nil, slot: record.slot, previousAccepted: false).write(state)
        return after
    }

    /// Writes a file only when it reads back as exactly that section and that text.
    static func write(_ contents: String, section: String, text: String, to file: URL) throws {
        guard case .success(let back) = parse(contents), back.text == text,
              back.section.trimmingCharacters(in: .newlines) == section.trimmingCharacters(in: .newlines) else {
            throw Refused.file(.ambiguousMarkers)
        }
        try AtomicFile.write(Data(contents.utf8), to: file, mode: 0o644)
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

    /// Sprava's record, `.sprava/instructions.json`, as the writer keeps it. One missing or unreadable is empty: nothing
    /// accepted and no Undo.
    struct Record {
        var accepted: String?
        var undoAfter: String?
        /// Which of `slots` holds the file the last save replaced.
        var slot: String?
        var previousAccepted = false

        init(accepted: String?, undoAfter: String?, slot: String?, previousAccepted: Bool) {
            self.accepted = accepted
            self.undoAfter = undoAfter
            self.slot = slot
            self.previousAccepted = previousAccepted
        }

        init(_ folder: URL) {
            let (accepted, undoAfter) = BinderInstructions.record(folder)
            self.accepted = accepted
            self.undoAfter = undoAfter
            guard case .ok(let data) = SafeFile.read(folder.appendingPathComponent(recordPath), under: folder, limit: 64 * 1024),
                  let value = try? JSONParser.parse(data).value else { return }
            slot = value["undo_slot"]?.stringValue.flatMap { slots.contains($0) ? $0 : nil }
            previousAccepted = value["previous_accepted"] == .bool(true)
        }

        func with(accepted: String) -> Record {
            var r = self
            r.accepted = accepted
            return r
        }

        func write(_ state: StateDirectory) throws {
            let record = JSONValue.obj([("accepted", accepted.map(JSONValue.string) ?? .null),
                                        ("undo_after", undoAfter.map(JSONValue.string) ?? .null),
                                        ("undo_slot", slot.map(JSONValue.string) ?? .null),
                                        ("previous_accepted", .bool(previousAccepted))])
            try state.write(Data(JSONWriter.pretty(record).utf8), to: (recordPath as NSString).lastPathComponent)
        }
    }
}
