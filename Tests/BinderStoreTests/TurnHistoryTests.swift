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

    @Test func aCaseOnlyRenameUndoesWithoutLosingTheFile() throws {
        let f = try Fixture()
        try f.write("Invented report", "Report.txt")
        try f.history.record(f.folder)
        let turn = UUID()
        try f.remove("Report.txt"); try f.write("Invented report", "report.txt")
        try f.history.record(f.folder, turn: turn)
        #expect(try f.history.undo(turn: turn, in: f.folder) == .undone)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.folder.path) == ["Report.txt"])
        #expect(f.read("Report.txt") == "Invented report")
    }

    @Test func somethingNowWhereAFileGoesIsAConflictAndEverythingMovesBack() throws {
        let f = try Fixture()
        try f.write("Invented notes", "z.txt")
        try f.history.record(f.folder)
        let turn = UUID()
        try f.remove("z.txt"); try f.write("Invented notes", "a.txt")
        try f.history.record(f.folder, turn: turn)
        try f.write("a person's file", "z.txt/inside.txt")
        #expect(try f.history.undo(turn: turn, in: f.folder) == .conflict(["z.txt"]))
        #expect(f.read("a.txt") == "Invented notes")
        #expect(f.read("z.txt/inside.txt") == "a person's file")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.folder.path).sorted() == ["a.txt", "z.txt"])
        #expect(try f.history.entry(forTurn: turn)?.undone == false)
    }

    @Test func aFilingDuringTheTurnRefusesUndoSoTheCatalogStaysTrue() throws {
        let f = try Fixture()
        try f.write("{}", "catalog.json"); try f.write("Invented notice", "intake/notice.txt")
        try f.history.record(f.folder)
        let turn = UUID()
        try f.remove("intake/notice.txt"); try f.write("Invented notice", "documents/notice.txt")
        try f.write("{\"documents\":[{\"path\":\"documents/notice.txt\"}]}", "catalog.json")
        try f.history.record(f.folder, turn: turn)
        #expect(try f.history.undo(turn: turn, in: f.folder) == .recordsChanged)
        #expect(f.read("documents/notice.txt") == "Invented notice")
        #expect(!f.exists("intake/notice.txt"))
    }

    @Test func aFileMadeInATurnAndFiledSinceIsNotDeletedByItsUndo() throws {
        let f = try Fixture()
        try f.write("{\"documents\":[]}", "catalog.json"); try f.history.record(f.folder)
        let turn = UUID()
        try f.write("Invented bylaw", "documents/bylaw.txt")
        try f.history.record(f.folder, turn: turn)
        try f.write("{\"documents\":[{\"path\":\"documents/bylaw.txt\"}]}", "catalog.json")
        #expect(try f.history.undo(turn: turn, in: f.folder) == .recordsChanged)
        #expect(f.read("documents/bylaw.txt") == "Invented bylaw")
    }

    @Test func aPipeOrLinkAtTheCatalogIsRefusedRatherThanRead() throws {
        let f = try Fixture()
        try f.write("plain", "notes.md"); try f.history.record(f.folder)
        #expect(mkfifo(f.folder.appendingPathComponent("catalog.json").path, 0o600) == 0)
        #expect(throws: TurnHistory.Refused.unreadable("catalog.json")) { try f.history.record(f.folder) }
        try f.remove("catalog.json")
        try FileManager.default.createSymbolicLink(atPath: f.folder.appendingPathComponent("catalog.json").path, withDestinationPath: "/etc/hosts")
        #expect(throws: TurnHistory.Refused.unreadable("catalog.json")) { try f.history.record(f.folder) }
    }

    @Test func aHugeSparseFileIsTrackedByNameAndNotReadAndSaysUndoCannotReturnIt() throws {
        let f = try Fixture()
        let url = f.folder.appendingPathComponent("intake/huge.bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        #expect(truncate(url.path, 1 << 40) == 0)
        let started = Date()
        try f.history.record(f.folder)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: f.history.blobs.path).filter { $0.contains("/") }.isEmpty)
        let turn = UUID()
        try f.remove("intake/huge.bin")
        let entry = try #require(try f.history.record(f.folder, turn: turn))
        #expect(entry.notRestorable == ["intake/huge.bin"])
    }

    @Test func stoppingEndsARecordWithoutLeavingItHalfDone() throws {
        let f = try Fixture()
        try f.write("plain", "notes.md"); try f.history.record(f.folder)
        try f.write("changed", "notes.md")
        #expect(throws: TurnHistory.Refused.cancelled) { try f.history.record(f.folder, cancelled: { true }) }
        // The change is still seen by the next record: nothing was taken as recorded.
        let entry = try #require(try f.history.record(f.folder, turn: UUID()))
        #expect(entry.summary == "Changed 1 file: notes.md")
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
