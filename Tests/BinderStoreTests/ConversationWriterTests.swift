import BinderFormat
@testable import BinderStore
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// The conversation history's writer (binder-v0 §7.2.1): whole messages appended and flushed, a torn group set aside,
/// a full month refused without writing. Invented binders and messages only.
@Suite(.serialized) struct ConversationWriterTests {
    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: Date(timeIntervalSince1970: 1_791_360_000))
        return (folder, store)
    }

    func message(_ n: Int, text: String = "Renew the invented permit on Friday.", at: String = "2026-10-16T12:00:00Z") throws -> ConversationMessage {
        try ConversationMessage(id: String(format: "0199e9e6-3c00-7000-8000-%012d", n), turn: "0199e9e6-3c00-7000-8000-000000000002",
                                at: at, speaker: .person, origin: .app, text: text, device: "device-example",
                                requestID: "0199e9e6-3c00-7000-8000-000000000003")
    }

    func read(_ folder: URL, _ month: String = "2026-10") -> ConversationHistory.Month? {
        if case .month(let m) = ConversationHistory.read(month: month, in: folder) { return m }
        return nil
    }

    func mode(_ url: URL) -> mode_t {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_mode & 0o777 : 0
    }

    @Test func appendsWholeMessagesToTheirMonthPrivately() throws {
        let (folder, store) = try adopted()
        var flushes = 0
        store.testHookFullSync = { _ in flushes += 1; return 0 }
        let long = try message(2, text: String(repeating: "\u{1F600}", count: 40_000))
        try store.appendConversation(try message(1))
        try store.appendConversation(long)
        try store.appendConversation(try message(3, at: "2026-11-01T00:00:00Z"))
        #expect(read(folder)?.messages == [try message(1), long])
        #expect(read(folder)?.damage == [])
        #expect(read(folder, "2026-11")?.messages == [try message(3, at: "2026-11-01T00:00:00Z")])
        #expect(flushes >= 3)
        let dir = folder.appendingPathComponent(".sprava/conversation")
        #expect(mode(dir) == 0o700)
        #expect(mode(dir.appendingPathComponent("2026-10.ndjson")) == 0o600)
    }

    @Test func aFailedFlushFailsTheAppend() throws {
        let (_, store) = try adopted()
        store.testHookFlushFails = { $0 == "flush the conversation history" }
        #expect(throws: (any Error).self) { try store.appendConversation(try message(1)) }
    }

    @Test func aTornGroupIsSetAsideAndCutBeforeTheNextMessage() throws {
        let (folder, store) = try adopted()
        try store.appendConversation(try message(1))
        let url = folder.appendingPathComponent(".sprava/conversation/2026-10.ndjson")
        let torn = try message(2, text: String(repeating: "a", count: 100_000)).lines()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: torn[0] + torn[1].prefix(100))
        try handle.close()

        try store.appendConversation(try message(3))
        #expect(read(folder)?.messages.map(\.id) == [try message(1).id, try message(3).id])
        #expect(read(folder)?.damage == [])
        let tornDir = folder.appendingPathComponent(".sprava/torn")
        let saved = try FileManager.default.contentsOfDirectory(atPath: tornDir.path).filter { $0.hasPrefix("conversation-2026-10-") }
        #expect(saved.count == 1)
        #expect(try Data(contentsOf: tornDir.appendingPathComponent(saved[0])) == torn[0] + torn[1].prefix(100))
    }

    @Test func aFullMonthRefusesTheWholeMessage() throws {
        let (folder, store) = try adopted()
        try store.appendConversation(try message(1))
        let url = folder.appendingPathComponent(".sprava/conversation/2026-10.ndjson")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x0A, count: ConversationLimits.monthLines - 1))
        try handle.close()
        let before = try Data(contentsOf: url)
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(try message(2)) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aMessageThatCannotBeStoredWholeWritesNothing() throws {
        let (folder, store) = try adopted()
        let wide = try (0..<64).map { _ in try ConversationMessage.Reference(kind: .op, id: .string(String(repeating: "\u{01}", count: 1024))) }
        let tooLong = try ConversationMessage(id: "0199e9e6-3c00-7000-8000-000000000009", turn: "0199e9e6-3c00-7000-8000-000000000002",
                                              at: "2026-10-16T12:00:00Z", speaker: .person, origin: .app,
                                              text: String(repeating: "\u{01}", count: 2_000_000), references: wide,
                                              device: "device-example", requestID: "0199e9e6-3c00-7000-8000-000000000003")
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(tooLong) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava/conversation/2026-10.ndjson").path))
    }

    @Test func aMessageTheReaderWouldRefuseIsNotSaved() throws {
        let (folder, store) = try adopted()
        let base = try message(1)
        for extra in [JSONObject([(key: "note", value: .str("a")), (key: "note", value: .str("b"))]),
                      JSONObject([(key: "size", value: .number(JSONNumber(text: "1e400")))])] {
            let odd = try ConversationMessage(id: base.id, turn: base.turn, at: base.at, speaker: .person, origin: .app, text: base.text,
                                              device: base.device, requestID: base.requestID, extra: extra)
            #expect(throws: TekaStore.Refused.self) { try store.appendConversation(odd) }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava/conversation/2026-10.ndjson").path))
    }

    @Test func aHistoryFoundOpenToOthersIsMadePrivateBeforeAppending() throws {
        let (folder, store) = try adopted()
        try store.appendConversation(try message(1))
        let dir = folder.appendingPathComponent(".sprava/conversation")
        let url = dir.appendingPathComponent("2026-10.ndjson")
        #expect(chmod(url.path, 0o644) == 0 && chmod(dir.path, 0o755) == 0)
        try store.appendConversation(try message(2))
        #expect(mode(url) == 0o600 && mode(dir) == 0o700)
        #expect(read(folder)?.messages.count == 2)
    }

    @Test func aMessageIDAlreadyInTheMonthIsRefused() throws {
        let (folder, store) = try adopted()
        try store.appendConversation(try message(1))
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(try message(1, text: "Different invented words")) }
        // An id written with escapes is the same id to the reader.
        let url = folder.appendingPathComponent(".sprava/conversation/2026-10.ndjson")
        let escaped = String(decoding: try message(2).lines()[0], as: UTF8.self)
            .replacingOccurrences(of: "\"id\":\"0199", with: "\"id\":\"\\u00301\\u00399")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(escaped.utf8))
        try handle.close()
        #expect(read(folder)?.messages.count == 2)
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(try message(2)) }
        #expect(read(folder)?.damage == [])
    }

    @Test func aMonthFileLinkedToAnotherFileIsNeverWritten() throws {
        let (folder, store) = try adopted()
        let dir = folder.appendingPathComponent(".sprava/conversation")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let catalog = folder.appendingPathComponent("catalog.json")
        let before = try Data(contentsOf: catalog)
        #expect(link(catalog.path, dir.appendingPathComponent("2026-10.ndjson").path) == 0)
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(try message(1)) }
        #expect(try Data(contentsOf: catalog) == before)
    }

    func appendRaw(_ data: Data, to folder: URL) throws {
        let url = folder.appendingPathComponent(".sprava/conversation/2026-10.ndjson")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    func tornCopies(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".sprava/torn").path)) ?? [])
            .filter { $0.hasPrefix("conversation-") }
    }

    @Test func aMonthTheReaderRefusesIsNeverRepairedOrAppendedTo() throws {
        let (folder, store) = try adopted()
        try store.appendConversation(try message(1))
        let url = folder.appendingPathComponent(".sprava/conversation/2026-10.ndjson")
        // Damage before the end stays for repair.
        try appendRaw(Data("not a record\n".utf8) + (try message(2).lines()[0]), to: folder)
        var before = try Data(contentsOf: url)
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(try message(3)) }
        #expect(try Data(contentsOf: url) == before && tornCopies(folder).isEmpty)

        // A line over 512 KiB is refused unread, a whole valid array included, never parsed to scan ids.
        try FileManager.default.removeItem(at: url)
        try store.appendConversation(try message(1))
        try appendRaw(Data(("[" + String(repeating: "0,", count: 300_000) + "0]\n").utf8), to: folder)
        before = try Data(contentsOf: url)
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(try message(3)) }
        #expect(try Data(contentsOf: url) == before)

        // Over the line limit with a torn tail: refused whole, the tail neither copied nor cut.
        try FileManager.default.removeItem(at: url)
        try store.appendConversation(try message(1))
        try appendRaw(Data(repeating: 0x0A, count: ConversationLimits.monthLines) + Data("{\"torn".utf8), to: folder)
        before = try Data(contentsOf: url)
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(try message(3)) }
        #expect(try Data(contentsOf: url) == before && tornCopies(folder).isEmpty)
    }

    @Test func onlyACrashsTailIsCutAndEarlierCopiesAreKept() throws {
        let (folder, store) = try adopted()
        try store.appendConversation(try message(1))
        let url = folder.appendingPathComponent(".sprava/conversation/2026-10.ndjson")
        // An unfinished group at the end that reuses an earlier id is damage to repair, not a crash's tail.
        try appendRaw(try message(1, text: String(repeating: "a", count: 100_000)).lines()[0], to: folder)
        let before = try Data(contentsOf: url)
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(try message(3)) }
        #expect(try Data(contentsOf: url) == before && tornCopies(folder).isEmpty)

        // Two crashes' tails in one second each keep their own copy.
        try FileManager.default.removeItem(at: url)
        try store.appendConversation(try message(1))
        try appendRaw(Data("{\"first torn".utf8), to: folder)
        try store.appendConversation(try message(4))
        try appendRaw(Data("{\"second torn".utf8), to: folder)
        try store.appendConversation(try message(5))
        #expect(tornCopies(folder).count == 2)
        #expect(read(folder)?.messages.count == 3)
    }

    @Test func aMonthLinkedToAFileWithoutAFinalNewlineIsNotCopiedAside() throws {
        let (folder, store) = try adopted()
        let dir = folder.appendingPathComponent(".sprava/conversation")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outside = folder.appendingPathComponent("documents-outside.txt")
        try Data("invented secret without a final newline".utf8).write(to: outside)
        #expect(link(outside.path, dir.appendingPathComponent("2026-10.ndjson").path) == 0)
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(try message(1)) }
        #expect(tornCopies(folder).isEmpty)
        #expect(try Data(contentsOf: outside) == Data("invented secret without a final newline".utf8))
    }

    @Test func aLinkedFolderOrFileIsNeverWrittenThrough() throws {
        let (folder, store) = try adopted()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let dir = folder.appendingPathComponent(".sprava/conversation")
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: outside)
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(try message(1)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)

        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("target.ndjson")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("2026-10.ndjson"), withDestinationURL: target)
        #expect(throws: TekaStore.Refused.self) { try store.appendConversation(try message(1)) }
        #expect(try Data(contentsOf: target).isEmpty)
    }
}
