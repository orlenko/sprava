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
    /// Tests only: runs after the last comparison and right before the new file takes the old one's place.
    package var testHookBeforeSwap: (@Sendable () -> Void)?

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
        case .unreadable(let why): throw TekaStore.Refused(reason: "DASHBOARD.md cannot be read now (\(why)); it was left as it is")
        case .missing: return nil
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
    func rewrite<T>(now: Date, _ render: (_ found: String?) throws -> (text: String?, result: T)) throws -> T {
        for _ in 0..<5 {
            let found = try found()
            let (text, result) = try render(found)
            guard let text else { return result }
            testHookBeforeWrite?()
            if text == found, try self.found() == found { return result }
            if text != found, try replace(found, with: text, now: now) { return result }
        }
        throw TekaStore.Refused(reason: "DASHBOARD.md kept changing while it was rendered; it was left as it is")
    }

    /// Puts `text` in place of the file read as `found`; false when the file changed first, to render again. The new
    /// file is written and flushed beside the old one before the last comparison, and takes its place by exchanging
    /// the two names, so the file it displaces can still be checked: when an editor saved in the instant between, its
    /// version is put back in place and the rendering starts again from it. Anything else found in that instant is
    /// kept under `.sprava/adopted/`.
    func replace(_ found: String?, with text: String, now: Date) throws -> Bool {
        let staged = folder.appendingPathComponent(".DASHBOARD-\(UUID().uuidString.lowercased()).tmp")
        // The new file never reads wider than the one it replaces: a dashboard the person made private (0600, say)
        // stays so, and so does the staged copy. A new dashboard is 0644, like the catalog a template writes.
        var st = stat()
        let mode: mode_t = found != nil && lstat(fileURL.path, &st) == 0 ? st.st_mode & 0o666 : 0o644
        try AtomicFile.write(Data(text.utf8), to: staged, mode: mode)
        // The staged name is removed unless it may hold a version no copy has kept yet.
        var keepStaged = false
        defer { if !keepStaged { unlink(staged.path) } }
        guard try self.found() == found else { return false }
        func synced() -> Bool {
            let dir = open(folder.path, O_RDONLY | O_CLOEXEC)
            if dir >= 0 { fsync(dir); close(dir) }
            return true
        }
        testHookBeforeSwap?()
        guard found != nil else {
            // No file was there: the new one never replaces a file an editor created meanwhile.
            if renamex_np(staged.path, fileURL.path, UInt32(RENAME_EXCL)) == 0 { return synced() }
            guard errno == EEXIST else { throw AtomicFile.Failure(step: "write DASHBOARD.md", code: errno) }
            return false
        }
        guard renamex_np(staged.path, fileURL.path, UInt32(RENAME_SWAP)) == 0 else {
            throw AtomicFile.Failure(step: "replace DASHBOARD.md", code: errno)
        }
        // `staged` now names the displaced file.
        func contents(at url: URL) -> String? {
            if case .ok(let data) = SafeFile.read(url, limit: 4 * 1024 * 1024) { return String(decoding: data, as: UTF8.self) }
            return nil
        }
        if contents(at: staged) == found { return synced() }
        keepStaged = true
        guard renamex_np(staged.path, fileURL.path, UInt32(RENAME_SWAP)) == 0 else {
            throw AtomicFile.Failure(step: "put DASHBOARD.md back", code: errno)
        }
        // Whatever the swap back displaced, unless it is this rendering, was saved in that instant too: it is kept.
        guard let back = contents(at: staged) else { return false }
        if back != text { try keepCopy(back, now: now) }
        keepStaged = false
        return false
    }

    func save(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(state), to: stateURL)
    }

    /// An unknown level, a broken stamp or another state that blocks writes blocks the dashboard too: it is rendered
    /// for display only, and the file and its state are left as they are (binder-v0 §9.6).
    static func checkWritable(_ teka: Teka) throws {
        guard teka.writesBlocked else { return }
        throw TekaStore.Refused(reason: "DASHBOARD.md is not written until this is repaired: " + teka.reasons.joined(separator: "; "))
    }

    /// The approved switch: the old text goes into Notes, headings demoted, and a copy is kept.
    public func switchOn(today: CalendarDate, timeZone: TimeZone = .current, now: Date = Date()) throws {
        try TekaStore(folder: folder).withLock {
            let teka = Teka.read(folder)
            guard teka.isAdopted, let catalog = teka.catalog else { throw TekaStore.Refused(reason: "not adopted") }
            try Self.checkWritable(teka)
            var st = stat()
            if lstat(fileURL.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG { throw TekaStore.Refused(reason: "DASHBOARD.md is not a regular file") }
            _ = try load()   // a state file that cannot be read is reported, never saved over
            try rewrite(now: now) { old in
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
            let teka = Teka.read(folder)
            guard let catalog = teka.catalog else { return .unchanged }
            try Self.checkWritable(teka)
            let hash = try Canonical.hash(.object(catalog))
            let outcome: Refresh = try rewrite(now: now) { found in
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
