import Darwin
import Foundation

/// Keeps a binder's `DASHBOARD.md` once the person approved the switch (binder-v0 §7.1). Before the switch nothing
/// is written; the app shows the rendering in its own window.
public struct DashboardKeeper: Sendable {
    public let folder: URL
    public let impl: String

    public init(folder: URL, impl: String = "sprava/0.1") {
        self.folder = folder
        self.impl = impl
    }

    var stateURL: URL { folder.appendingPathComponent(".sprava/dashboard.json") }
    var fileURL: URL { folder.appendingPathComponent("DASHBOARD.md") }

    struct State: Codable {
        var switched: Bool
        var switchedAt: String?
        var catalogHash: String?
        var day: String?
    }

    func load() -> State? { (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } }

    public var isSwitched: Bool { load()?.switched == true }

    /// The file as found, when it is a regular file of this user (never through a link).
    func current() -> String? {
        guard case .ok(let data) = SafeFile.read(fileURL, limit: 4 * 1024 * 1024) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    var hasManual: Bool {
        var st = stat()
        return lstat(folder.appendingPathComponent("CLAUDE.md").path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }

    /// What the dashboard would hold today, for the app's own window; writes nothing.
    public func preview(today: CalendarDate, timeZone: TimeZone = .current) -> String? {
        guard let catalog = Teka.read(folder).catalog else { return nil }
        let notes = current().flatMap { Dashboard.split($0).1 }
        return Dashboard.render(catalog: catalog, folderName: folder.lastPathComponent, today: today, timeZone: timeZone,
                                hasManual: hasManual, notes: notes, impl: impl)
    }

    func keepCopy(_ text: String, now: Date) throws {
        let dir = folder.appendingPathComponent(".sprava/adopted", isDirectory: true)
        try AtomicFile.makePrivateFolder(dir)
        let stamp = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!).replacingOccurrences(of: ":", with: "")
        try AtomicFile.write(Data(text.utf8), to: dir.appendingPathComponent("DASHBOARD-\(stamp).md"))
    }

    func save(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(state), to: stateURL)
    }

    /// The approved switch: the old text goes into Notes, headings demoted, and a copy is kept.
    public func switchOn(today: CalendarDate, timeZone: TimeZone = .current, now: Date = Date()) throws {
        try TekaStore(folder: folder).withLock {
            guard Teka.read(folder).isAdopted, let catalog = Teka.read(folder).catalog else { throw TekaStore.Refused(reason: "not adopted") }
            var st = stat()
            if lstat(fileURL.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG { throw TekaStore.Refused(reason: "DASHBOARD.md is not a regular file") }
            let old = current()
            var notes: String?
            if let old {
                try keepCopy(old, now: now)
                notes = Dashboard.editedOutsideNotes(old) ? Dashboard.notesFromOld(old) : Dashboard.split(old).1
            }
            let text = Dashboard.render(catalog: catalog, folderName: folder.lastPathComponent, today: today, timeZone: timeZone,
                                        hasManual: hasManual, notes: notes, impl: impl)
            try AtomicFile.write(Data(text.utf8), to: fileURL, mode: 0o644)
            try save(State(switched: true, switchedAt: ISOTime.string(now), catalogHash: try Canonical.hash(.object(catalog)), day: today.description))
        }
    }

    public enum Refresh: Equatable { case notSwitched, unchanged, rendered(editedOutsideNotes: Bool) }

    /// Renders again when the catalog changed or the day turned. An edit outside Notes is saved first.
    public func refresh(today: CalendarDate, timeZone: TimeZone = .current, now: Date = Date()) throws -> Refresh {
        guard var state = load(), state.switched else { return .notSwitched }
        return try TekaStore(folder: folder).withLock {
            guard let catalog = Teka.read(folder).catalog else { return .unchanged }
            let hash = try Canonical.hash(.object(catalog))
            let found = current()
            if hash == state.catalogHash, today.description == state.day, let found, !Dashboard.editedOutsideNotes(found) { return .unchanged }
            var edited = false
            if let found, Dashboard.editedOutsideNotes(found) {
                try keepCopy(found, now: now)
                edited = true
            }
            let text = Dashboard.render(catalog: catalog, folderName: folder.lastPathComponent, today: today, timeZone: timeZone,
                                        hasManual: hasManual, notes: found.flatMap { Dashboard.split($0).1 }, impl: impl)
            if text != found { try AtomicFile.write(Data(text.utf8), to: fileURL, mode: 0o644) }
            state.catalogHash = hash
            state.day = today.description
            try save(state)
            return .rendered(editedOutsideNotes: edited)
        }
    }
}
