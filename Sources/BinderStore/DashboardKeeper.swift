import BinderFormat
import Darwin
import Foundation
import SpravaKit

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

    /// Tests only: runs after a rendering and right before the file is read again to be replaced.
    package var testHookBeforeWrite: (@Sendable () -> Void)?

    /// The saved state; nil when there is none. A state file that exists but cannot be read or decoded throws, so an
    /// enabled dashboard never silently stops being kept and the file is never saved over.
    func load() throws -> State? { try StateFile.read(State.self, from: stateURL) }

    /// For display only: false when the state cannot be read; `refresh` and `switchOn` report that instead.
    public var isSwitched: Bool { ((try? load()) ?? nil)?.switched == true }

    /// The file as found, when it is a regular file of this user (never through a link); nil when there is none.
    /// A file that exists but cannot be read (too large, another owner, a link, a failed open) throws, so it is
    /// never written over and its Notes are never lost.
    func found() throws -> String? {
        switch SafeFile.read(fileURL, limit: 4 * 1024 * 1024) {
        case .ok(let data): return String(decoding: data, as: UTF8.self)
        case .refused(let why): throw TekaStore.Refused(reason: "DASHBOARD.md cannot be read (\(why)); it was left as it is")
        case .missing:
            var st = stat()
            if lstat(fileURL.path, &st) != 0, errno == ENOENT { return nil }
            throw TekaStore.Refused(reason: "DASHBOARD.md cannot be read; it was left as it is")
        }
    }

    /// The file as found, for reading only; nil when there is none or it cannot be read.
    func current() -> String? { (try? found()) ?? nil }

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
        // A copy may be the only record of an edit, so it never replaces another: two saved in the same second get
        // `-2`, `-3` and so on, and the exclusive rename refuses a name taken meanwhile.
        let temp = dir.appendingPathComponent(".DASHBOARD-\(UUID().uuidString.lowercased()).tmp")
        try AtomicFile.write(Data(text.utf8), to: temp)
        defer { unlink(temp.path) }
        for n in 1...1000 {
            let name = n == 1 ? "DASHBOARD-\(stamp).md" : "DASHBOARD-\(stamp)-\(n).md"
            if renamex_np(temp.path, dir.appendingPathComponent(name).path, UInt32(RENAME_EXCL)) == 0 { return }
            guard errno == EEXIST else { throw AtomicFile.Failure(step: "keep a copy of DASHBOARD.md", code: errno) }
        }
        throw TekaStore.Refused(reason: "too many copies of DASHBOARD.md were kept in one second; it was left as it is")
    }

    /// Replaces the file with what `render` makes of it as found, reading it again right before the write: an editor
    /// does not take the binder lock, so Notes saved while the rendering ran would otherwise be lost. A change seen
    /// there renders again from the new bytes. A nil text writes nothing.
    func rewrite<T>(_ render: (_ found: String?) throws -> (text: String?, result: T)) throws -> T {
        for _ in 0..<5 {
            let found = try found()
            let (text, result) = try render(found)
            guard let text else { return result }
            testHookBeforeWrite?()
            guard try self.found() == found else { continue }
            if text != found { try AtomicFile.write(Data(text.utf8), to: fileURL, mode: 0o644) }
            return result
        }
        throw TekaStore.Refused(reason: "DASHBOARD.md kept changing while it was rendered; it was left as it is")
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
            _ = try load()   // a state file that cannot be read is reported, never saved over
            try rewrite { old in
                var notes: String?
                if let old {
                    try keepCopy(old, now: now)
                    notes = Dashboard.editedOutsideNotes(old) ? Dashboard.notesFromOld(old) : Dashboard.split(old).1
                }
                return (Dashboard.render(catalog: catalog, folderName: folder.lastPathComponent, today: today, timeZone: timeZone,
                                         hasManual: hasManual, notes: notes, impl: impl), ())
            }
            try save(State(switched: true, switchedAt: ISOTime.string(now), catalogHash: try Canonical.hash(.object(catalog)), day: today.description))
        }
    }

    public enum Refresh: Equatable { case notSwitched, unchanged, rendered(editedOutsideNotes: Bool) }

    /// Renders again when the catalog changed or the day turned. An edit outside Notes is saved first.
    public func refresh(today: CalendarDate, timeZone: TimeZone = .current, now: Date = Date()) throws -> Refresh {
        guard var state = try load(), state.switched else { return .notSwitched }
        return try TekaStore(folder: folder).withLock {
            guard let catalog = Teka.read(folder).catalog else { return .unchanged }
            let hash = try Canonical.hash(.object(catalog))
            let outcome: Refresh = try rewrite { found in
                if hash == state.catalogHash, today.description == state.day, let found, !Dashboard.editedOutsideNotes(found) {
                    return (nil, .unchanged)
                }
                var edited = false
                if let found, Dashboard.editedOutsideNotes(found) {
                    try keepCopy(found, now: now)
                    edited = true
                }
                return (Dashboard.render(catalog: catalog, folderName: folder.lastPathComponent, today: today, timeZone: timeZone,
                                         hasManual: hasManual, notes: found.flatMap { Dashboard.split($0).1 }, impl: impl),
                        .rendered(editedOutsideNotes: edited))
            }
            guard outcome != .unchanged else { return .unchanged }
            state.catalogHash = hash
            state.day = today.description
            try save(state)
            return outcome
        }
    }
}
