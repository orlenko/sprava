@testable import BinderStore
import Darwin
import Foundation
import Testing

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// Invented fixtures only.
@Suite struct TurnHistoryTests {
    struct Fixture {
        let folder: URL
        let history: TurnHistory
        init() throws {
            let root = try temporaryFolder()
            folder = root.appendingPathComponent("workshop")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            history = TurnHistory(support: root.appendingPathComponent("support"), binder: UUID())
        }
        func write(_ text: String, _ path: String) throws {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func read(_ path: String) -> String? { (try? Data(contentsOf: folder.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) } }
        func remove(_ path: String) throws { try FileManager.default.removeItem(at: folder.appendingPathComponent(path)) }
        func exists(_ path: String) -> Bool { var info = stat(); return lstat(folder.appendingPathComponent(path).path, &info) == 0 }
    }

    @Test func undoBringsBackADeletedFileAndRevertsEditsAndAdditions() throws {
        let f = try Fixture()
        try f.write("Invented bylaw", "documents/bylaw.txt")
        try f.write("first", "notes.md")
        #expect(try f.history.record(f.folder) == nil) // Baseline.
        let turn = UUID()
        try f.remove("documents/bylaw.txt")
        try f.write("second", "notes.md")
        try f.write("new", "drafts/deep/letter.md")
        let entry = try #require(try f.history.record(f.folder, turn: turn))
        #expect(entry.summary == "Added 1 file, changed 1 file, deleted 1 file: documents/bylaw.txt, drafts/deep/letter.md, notes.md")
        #expect(try f.history.undo(turn: turn, in: f.folder) == .undone)
        #expect(f.read("documents/bylaw.txt") == "Invented bylaw")
        #expect(f.read("notes.md") == "first")
        #expect(!f.exists("drafts"))
        #expect(try f.history.entry(forTurn: turn)?.undone == true)
        // Undoing twice changes nothing more.
        try f.write("third", "notes.md")
        #expect(try f.history.undo(turn: turn, in: f.folder) == .undone)
        #expect(f.read("notes.md") == "third")
    }

    @Test func undoNeverDeletesWhatArrivedInIntakeDuringTheTurn() throws {
        let f = try Fixture()
        try f.write("first", "notes.md")
        try f.history.record(f.folder)
        let turn = UUID()
        try f.write("second", "notes.md"); try f.write("Invented mail", "intake/mail/notice.md")
        try f.history.record(f.folder, turn: turn)
        #expect(try f.history.undo(turn: turn, in: f.folder) == .undone)
        #expect(f.read("notes.md") == "first")
        #expect(f.read("intake/mail/notice.md") == "Invented mail")
    }

    @Test func aLaterEditIsAConflictAndNothingMoves() throws {
        let f = try Fixture()
        try f.write("first", "notes.md"); try f.write("keep", "other.md")
        try f.history.record(f.folder)
        let turn = UUID()
        try f.write("second", "notes.md"); try f.remove("other.md")
        try f.history.record(f.folder, turn: turn)
        try f.write("the person's own words", "notes.md")
        #expect(try f.history.undo(turn: turn, in: f.folder) == .conflict(["notes.md"]))
        #expect(f.read("notes.md") == "the person's own words")
        #expect(!f.exists("other.md"))
        #expect(try f.history.entry(forTurn: turn)?.undone == false)
    }

    @Test func aFolderSwappedForALinkCannotCarryARestoredFileOutOfTheBinder() throws {
        let f = try Fixture()
        let outside = try temporaryFolder()
        try f.write("inside", "shared/notes.md")
        try f.history.record(f.folder)
        let turn = UUID()
        try f.remove("shared/notes.md")
        try f.history.record(f.folder, turn: turn)
        try f.remove("shared")
        try FileManager.default.createSymbolicLink(at: f.folder.appendingPathComponent("shared"), withDestinationURL: outside)
        #expect(try f.history.undo(turn: turn, in: f.folder) == .conflict(["shared/notes.md"]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func aKeyFileIsNeverCopiedAndItsDeletionSaysUndoCannotReturnIt() throws {
        let f = try Fixture()
        try f.write("INVENTED_SECRET=1", "scripts/.env"); try f.write("plain", "notes.md")
        try f.history.record(f.folder)
        let kept = try FileManager.default.subpathsOfDirectory(atPath: f.history.blobs.path)
            .filter { $0.contains("/") }
            .map { String(decoding: try Data(contentsOf: f.history.blobs.appendingPathComponent($0)), as: UTF8.self) }
        #expect(kept == ["plain"])
        let turn = UUID()
        try f.remove("scripts/.env"); try f.remove("notes.md")
        let entry = try #require(try f.history.record(f.folder, turn: turn))
        #expect(entry.notRestorable == ["scripts/.env"])
        #expect(entry.summary.contains("Undo cannot bring back: scripts/.env"))
        #expect(try f.history.undo(turn: turn, in: f.folder) == .undone)
        #expect(f.read("notes.md") == "plain")
        #expect(!f.exists("scripts/.env"))
    }

    @Test func aCopiedProjectsGitFolderAndLinksAreOrdinaryContent() throws {
        let f = try Fixture()
        try f.write("[core]", "project/.git/config")
        try FileManager.default.createSymbolicLink(atPath: f.folder.appendingPathComponent("link").path, withDestinationPath: "project/.git/config")
        try f.history.record(f.folder)
        let turn = UUID()
        try f.remove("project"); try f.remove("link")
        #expect(try f.history.record(f.folder, turn: turn)?.summary.hasPrefix("Deleted 2 files") == true)
        #expect(try f.history.undo(turn: turn, in: f.folder) == .undone)
        #expect(f.read("project/.git/config") == "[core]")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.folder.appendingPathComponent("link").path) == "project/.git/config")
    }

    @Test func theOwnersFilesAreNotVersionedAndATouchIsNotAChange() throws {
        let f = try Fixture()
        try f.write("{}", "catalog.json"); try f.write("# d", "DASHBOARD.md"); try f.write("log", ".sprava/ops.jsonl"); try f.write("same", "notes.md")
        try f.history.record(f.folder)
        try f.write("{\"a\":1}", "catalog.json"); try f.write("# e", "DASHBOARD.md"); try f.write("log2", ".sprava/ops.jsonl")
        try f.write("same", "notes.md") // New modification time, same bytes.
        #expect(try f.history.record(f.folder, turn: UUID()) == nil)
    }

    @Test func aPipeIsSkippedRatherThanReadAndHung() throws {
        let f = try Fixture()
        try f.write("plain", "notes.md")
        #expect(mkfifo(f.folder.appendingPathComponent("pipe").path, 0o600) == 0)
        #expect(try f.history.record(f.folder) == nil)
        #expect(try f.history.record(f.folder, turn: UUID()) == nil)
    }

    @Test func oldEntriesAndTheirBytesAreForgottenButCurrentFilesStay() throws {
        let f = try Fixture()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try f.write("old bytes", "notes.md")
        try f.history.record(f.folder, now: start)
        let turn = UUID()
        try f.write("current bytes", "notes.md")
        try f.history.record(f.folder, turn: turn, now: start)
        let later = start.addingTimeInterval(TimeInterval(TurnHistory.keepDays + 1) * 86_400)
        try f.history.prune(now: later)
        #expect(try f.history.entry(forTurn: turn) == nil)
        let kept = try FileManager.default.subpathsOfDirectory(atPath: f.history.blobs.path).filter { $0.contains("/") }
        #expect(kept.count == 1)
    }

    @Test func forgettingRemovesEveryCopy() throws {
        let f = try Fixture()
        try f.write("plain", "notes.md")
        try f.history.record(f.folder)
        try f.history.forget()
        #expect(!FileManager.default.fileExists(atPath: f.history.root.path))
    }

    @Test func aDamagedHeadIsReportedNotTakenForABaseline() throws {
        let f = try Fixture()
        try f.write("plain", "notes.md")
        try f.history.record(f.folder)
        try Data("not json".utf8).write(to: f.history.head)
        #expect(throws: TurnHistory.Refused.damaged) { try f.history.record(f.folder) }
    }
}
