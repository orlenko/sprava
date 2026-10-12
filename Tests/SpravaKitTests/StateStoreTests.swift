@testable import SpravaKit
import Darwin
import Foundation
import Testing

/// `StateStore` keeps Sprava's own state in SQLite (decisions.md A13): transactions are atomic and serialized
/// across connections, the file is private and never reached through a link, and a database it cannot use is
/// refused and left as it is. Invented data only.
@Suite struct StateStoreTests {
    struct Invented: Codable, Equatable { var note: String; var count: Int }

    static let schema = StateStore.Schema(version: 1, statements: [
        "CREATE TABLE counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL)",
    ])

    func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-state-store-\(UUID().uuidString)")
    }

    @Test func documentsAndRowsRoundTripAndSurviveReopening() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("support/runtime/services.sqlite")
        do {
            let store = try StateStore.open(file, schema: Self.schema)
            #expect(try store.read { try $0.document(Invented.self, key: "invented") } == nil)
            try store.write { t in
                try t.setDocument(Invented(note: "first", count: 1), key: "invented")
                try t.execute("INSERT INTO counters VALUES (?, ?)", .text("intake"), .integer(3))
            }
        }
        let store = try StateStore.open(file, schema: Self.schema)
        #expect(try store.read { try $0.document(Invented.self, key: "invented") } == Invented(note: "first", count: 1))
        #expect(try store.read { try $0.rows("SELECT name, value FROM counters") } == [[.text("intake"), .integer(3)]])
        try store.write { try $0.removeDocument(key: "invented") }
        #expect(try store.read { try $0.document(Invented.self, key: "invented") } == nil)
    }

    @Test func everyValueTypeRoundTrips() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try StateStore.open(base.appendingPathComponent("values.sqlite"), schema: .init(version: 1, statements: [
            "CREATE TABLE v (n, i, r, t, b, e)",
        ]))
        let row: [StateValue] = [.null, .integer(-7), .real(2.5), .text("Café ✓ invented"), .blob(Data([0, 1, 255])), .blob(Data())]
        try store.write { t in try t.execute("INSERT INTO v VALUES (?, ?, ?, ?, ?, ?)", row[0], row[1], row[2], row[3], row[4], row[5]) }
        #expect(try store.read { try $0.rows("SELECT * FROM v") } == [row])
    }

    /// Text is bound by its byte count, so a NUL inside it neither ends the text nor makes two keys one.
    @Test func textWithANulInsideKeepsEveryCharacter() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try StateStore.open(base.appendingPathComponent("s.sqlite"), schema: Self.schema)
        try store.write { t in
            try t.execute("INSERT INTO counters VALUES (?, 1)", .text("first\u{0}second"))
            try t.setDocument(Invented(note: "plain", count: 1), key: "note")
            try t.setDocument(Invented(note: "with nul", count: 2), key: "note\u{0}other")
            try t.execute("INSERT INTO counters VALUES (?, 2)", .text(""))
        }
        #expect(try store.read { try $0.rows("SELECT name FROM counters ORDER BY value") }
                == [[.text("first\u{0}second")], [.text("")]])
        #expect(try store.read { try $0.document(Invented.self, key: "note") } == Invented(note: "plain", count: 1))
        #expect(try store.read { try $0.document(Invented.self, key: "note\u{0}other") } == Invented(note: "with nul", count: 2))
    }

    @Test func aThrowRollsTheWholeTransactionBack() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try StateStore.open(base.appendingPathComponent("s.sqlite"), schema: Self.schema)
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try store.write { t in
                try t.execute("INSERT INTO counters VALUES ('intake', 1)")
                try t.setDocument(Invented(note: "half", count: 0), key: "invented")
                throw Stop()
            }
        }
        #expect(try store.read { try $0.rows("SELECT count(*) FROM counters") } == [[.integer(0)]])
        #expect(try store.read { try $0.document(Invented.self, key: "invented") } == nil)
        // The store is usable afterwards.
        try store.write { try $0.execute("INSERT INTO counters VALUES ('intake', 1)") }
    }

    /// Two connections stand in for two processes: read-change-write under BEGIN IMMEDIATE loses no update.
    @Test func concurrentWritersOnTwoConnectionsLoseNoUpdate() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("s.sqlite")
        let stores = [try StateStore.open(file, schema: Self.schema), try StateStore.open(file, schema: Self.schema)]
        try stores[0].write { try $0.execute("INSERT INTO counters VALUES ('n', 0)") }
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            do {
                try stores[i % 2].write { t in
                    let value = try t.rows("SELECT value FROM counters WHERE name = 'n'").first?.first?.integer ?? -1
                    try t.execute("UPDATE counters SET value = ? WHERE name = 'n'", .integer(value + 1))
                }
            } catch { failures.add() }
        }
        #expect(failures.value == 0)
        #expect(try stores[1].read { try $0.rows("SELECT value FROM counters") } == [[.integer(200)]])
    }

    @Test func theFileIsPrivateAndInWALMode() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("s.sqlite")
        let store = try StateStore.open(file, schema: Self.schema)
        try store.write { try $0.execute("INSERT INTO counters VALUES ('n', 1)") }
        #expect(try store.read { try $0.rows("PRAGMA journal_mode") } == [[.text("wal")]])
        for name in ["s.sqlite", "s.sqlite-wal"] {
            var info = stat()
            #expect(lstat(base.appendingPathComponent(name).path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        }
    }

    @Test func aLinkInPlaceOfTheFileOrItsFolderIsRefusedAndLeftAlone() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        try AtomicFile.makePrivateFolder(base)
        let outside = base.appendingPathComponent("outside.sqlite"), file = base.appendingPathComponent("s.sqlite")
        _ = try StateStore.open(outside, schema: Self.schema)
        let before = try Data(contentsOf: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try StateStore.open(file, schema: Self.schema) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == outside.path)
        #expect(try Data(contentsOf: outside) == before)
        // A linked folder is refused too.
        let realFolder = base.appendingPathComponent("real"), linkedFolder = base.appendingPathComponent("linked")
        try AtomicFile.makePrivateFolder(realFolder)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: realFolder)
        #expect(throws: (any Error).self) {
            try StateStore.open(linkedFolder.appendingPathComponent("s.sqlite"), schema: Self.schema)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: realFolder.path).isEmpty)
        // So is a folder standing where the file should be.
        let folderInPlace = base.appendingPathComponent("folder.sqlite")
        try FileManager.default.createDirectory(at: folderInPlace, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try StateStore.open(folderInPlace, schema: Self.schema) }
    }

    @Test func aFileThatIsNotADatabaseIsRefusedAndLeftAsItIs() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        try AtomicFile.makePrivateFolder(base)
        let file = base.appendingPathComponent("s.sqlite")
        let garbage = Data(repeating: 0x5A, count: 8192)
        try garbage.write(to: file)
        #expect(throws: StateStore.Failure.self) { try StateStore.open(file, schema: Self.schema) }
        #expect(try Data(contentsOf: file) == garbage)
    }

    /// No migrations before the MVP (decisions.md A14): another version throws, names the file, and changes nothing.
    @Test func anotherSchemaVersionThrowsAndChangesNothing() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("s.sqlite")
        try StateStore.open(file, schema: Self.schema).write { try $0.execute("INSERT INTO counters VALUES ('n', 4)") }
        let newer = StateStore.Schema(version: 2, statements: ["CREATE TABLE other (x)"])
        do {
            _ = try StateStore.open(file, schema: newer)
            Issue.record("a newer schema opened an older database")
        } catch let failure as StateStore.Failure {
            #expect(failure.description.contains(file.path) && failure.description.contains("A14"))
        }
        let store = try StateStore.open(file, schema: Self.schema)
        #expect(try store.read { try $0.rows("SELECT value FROM counters") } == [[.integer(4)]])
    }

    @Test func aDocumentThatDoesNotDecodeThrowsAndStays() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try StateStore.open(base.appendingPathComponent("s.sqlite"), schema: Self.schema)
        try store.write { try $0.execute("INSERT INTO sprava_documents VALUES ('invented', ?)", .blob(Data("not json".utf8))) }
        #expect(throws: StateStore.Failure.self) { try store.read { try $0.document(Invented.self, key: "invented") } }
        #expect(try store.read { try $0.rows("SELECT value FROM sprava_documents") } == [[.blob(Data("not json".utf8))]])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
