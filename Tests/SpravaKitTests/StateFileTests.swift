@testable import SpravaKit
import Darwin
import Foundation
import Testing

/// `StateFile` reads and writes through a handle on the file's folder: links are refused, not followed, and a
/// folder swapped for a link between the check and the open cannot redirect either. Invented data only.
@Suite struct StateFileTests {
    struct Invented: Codable, Equatable { var note: String }

    func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-state-file-\(UUID().uuidString)")
    }

    @Test func missingFilesAndFoldersReadAsNilAndWritesRoundTrip() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("support/capture/state.json")
        #expect(try StateFile.read(Invented.self, from: file) == nil)
        try StateFile.write(try JSONEncoder().encode(Invented(note: "invented")), to: file)
        #expect(try StateFile.read(Invented.self, from: file) == Invented(note: "invented"))
        try StateFile.write(try JSONEncoder().encode(Invented(note: "replaced")), to: file)
        #expect(try StateFile.read(Invented.self, from: file) == Invented(note: "replaced"))
        var info = stat()
        #expect(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }

    @Test func undecodableOrUnreadableFilesThrowAndAreLeftAlone() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        try AtomicFile.makePrivateFolder(base)
        let file = base.appendingPathComponent("state.json")
        try Data("not json".utf8).write(to: file)
        #expect(throws: StateFile.Unreadable.self) { try StateFile.read(Invented.self, from: file) }
        #expect(try Data(contentsOf: file) == Data("not json".utf8))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(throws: StateFile.Unreadable.self) { try StateFile.read(Invented.self, from: file) }
    }

    @Test func aLinkInPlaceOfTheFileIsRefusedNotFollowed() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        try AtomicFile.makePrivateFolder(base)
        let outside = base.appendingPathComponent("outside.json"), file = base.appendingPathComponent("state.json")
        try JSONEncoder().encode(Invented(note: "outside")).write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(throws: StateFile.Unreadable.self) { try StateFile.read(Invented.self, from: file) }
        // Nor is it replaced by a write: the link and what it points at stay as they were.
        #expect(throws: (any Error).self) { try StateFile.write(Data("{}".utf8), to: file) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == outside.path)
        #expect(try JSONDecoder().decode(Invented.self, from: Data(contentsOf: outside)) == Invented(note: "outside"))
        // A folder in the file's place is not replaced either.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try StateFile.write(Data("{}".utf8), to: file) }
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder) && isFolder.boolValue)
    }

    @Test func aFileNoReadAcceptsIsNotReplaced() throws {
        let base = temporary()
        defer { chmod(base.appendingPathComponent("state.json").path, 0o600); try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("state.json")
        try StateFile.write(try JSONEncoder().encode(Invented(note: "kept")), to: file)
        #expect(chmod(file.path, 0o000) == 0)
        #expect(throws: StateFile.Unreadable.self) { try StateFile.read(Invented.self, from: file) }
        #expect(throws: (any Error).self) { try StateFile.write(Data("{}".utf8), to: file) }
        #expect(chmod(file.path, 0o600) == 0)
        #expect(try StateFile.read(Invented.self, from: file) == Invented(note: "kept"))
    }

    @Test func aLinkPutInPlaceDuringAWriteIsNotReplaced() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = try #require(try StateDirectory.open(base, create: true))
        let outside = base.appendingPathComponent("outside.json"), file = base.appendingPathComponent("state.json")
        try Data("outside".utf8).write(to: outside)
        #expect(throws: (any Error).self) {
            try folder.write(Data("{}".utf8), to: "state.json", beforeOpen: {}, beforePublish: { _ in
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            })
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == outside.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).sorted() == ["outside.json", "state.json"])
    }

    @Test func dataLargerThanAReadAcceptsIsNeverWritten() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("state.json")
        try StateFile.write(try JSONEncoder().encode(Invented(note: "kept")), to: file)
        #expect(throws: (any Error).self) { try StateFile.write(Data(count: StateFile.limit + 1), to: file) }
        #expect(try StateFile.read(Invented.self, from: file) == Invented(note: "kept"))
    }

    @Test(arguments: [false, true]) func aLinkedOrSharedFolderIsRefused(shared: Bool) throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside"), folder = base.appendingPathComponent("support")
        try AtomicFile.makePrivateFolder(outside)
        try JSONEncoder().encode(Invented(note: "outside")).write(to: outside.appendingPathComponent("state.json"))
        if shared {
            try FileManager.default.moveItem(at: outside, to: folder)
            #expect(chmod(folder.path, 0o777) == 0)
        } else {
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        }
        let file = folder.appendingPathComponent("state.json")
        #expect(throws: StateFile.Unreadable.self) { try StateFile.read(Invented.self, from: file) }
        #expect(throws: (any Error).self) { try StateFile.write(Data("{}".utf8), to: file) }
        let left = shared ? file : outside.appendingPathComponent("state.json")
        #expect(try JSONDecoder().decode(Invented.self, from: Data(contentsOf: left)) == Invented(note: "outside"))
    }

    @Test(arguments: [false, true]) func aFolderSwappedForALinkCannotRedirectTheFile(writing: Bool) throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("support"), outside = base.appendingPathComponent("outside")
        let moved = base.appendingPathComponent("moved"), file = folder.appendingPathComponent("state.json")
        try StateFile.write(try JSONEncoder().encode(Invented(note: "old")), to: file)
        try StateFile.write(try JSONEncoder().encode(Invented(note: "outside")), to: outside.appendingPathComponent("state.json"))
        let swap = {
            try FileManager.default.moveItem(at: folder, to: moved)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        }
        if writing {
            #expect(throws: (any Error).self) { try StateFile.write(Data("{}".utf8), to: file, beforeOpen: swap) }
        } else {
            #expect(throws: StateFile.Unreadable.self) {
                try StateFile.read(Invented.self, from: file, decoder: JSONDecoder(), beforeOpen: swap)
            }
        }
        let read = { (url: URL) in try JSONDecoder().decode(Invented.self, from: Data(contentsOf: url)) }
        #expect(try read(outside.appendingPathComponent("state.json")) == Invented(note: "outside"))
        #expect(try read(moved.appendingPathComponent("state.json")) == Invented(note: "old"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path) == ["state.json"])
    }
}
