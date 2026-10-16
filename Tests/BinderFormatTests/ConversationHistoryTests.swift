@testable import BinderFormat
import Darwin
import Foundation
import SpravaKit
import Testing

/// The conversation history's line format and its one bounded reader (binder-v0 §7.2.1). Invented messages only.
@Suite struct ConversationHistoryTests {
    static let turn = "0199e9e6-3c00-7000-8000-000000000002"
    static let request = "0199e9e6-3c00-7000-8000-000000000003"

    func message(_ n: Int = 1, text: String = "Renew the invented permit on Friday.", at: String = "2026-10-16T12:00:00Z",
                 references: [ConversationMessage.Reference] = []) throws -> ConversationMessage {
        try ConversationMessage(id: String(format: "0199e9e6-3c00-7000-8000-%012d", n), turn: Self.turn, at: at,
                                speaker: .person, origin: .app, text: text, references: references,
                                device: "device-example", requestID: Self.request)
    }

    func bytes(_ messages: [ConversationMessage]) throws -> Data {
        try messages.flatMap { try $0.lines() }.reduce(Data(), +)
    }

    func month(_ data: Data, _ name: String = "2026-10") -> ConversationHistory.Month? {
        if case .month(let month) = ConversationHistory.read(data, month: name) { return month }
        return nil
    }

    func binder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-conversation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".sprava/conversation"), withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Writing lines

    @Test func aShortMessageIsOneLineThatReadsBack() throws {
        let original = try message()
        let lines = try original.lines()
        #expect(lines.count == 1)
        #expect(lines[0].last == 0x0A)
        let line = String(decoding: lines[0], as: UTF8.self)
        #expect(line.contains(#""part":1,"parts":1"#))
        #expect(month(lines[0])?.messages == [original])
        #expect(month(lines[0])?.damage == [])
    }

    @Test func splitMultibyteTextJoinsWithoutAlteration() throws {
        // Decomposed accents and four-byte scalars around every part boundary; nothing may be normalized or lost.
        let text = String(repeating: "e\u{0301}\u{1F600}x", count: 30_000) + "  trailing space \n"
        let original = try message(text: text)
        let lines = try original.lines()
        #expect(lines.count > 1)
        let read = try #require(month(lines.reduce(Data(), +)))
        #expect(read.damage == [])
        #expect(read.messages.count == 1)
        #expect(Array(read.messages[0].text.utf8) == Array(text.utf8))
        #expect(lines.allSatisfy { $0.count <= ConversationLimits.lineBytes })
    }

    @Test func escapedTextStaysUnderTheLineBound() throws {
        // A control character costs six bytes once escaped; the writer splits by the encoded size too.
        let text = String(repeating: "\u{01}", count: 200_000)
        let lines = try message(text: text).lines()
        #expect(lines.allSatisfy { $0.count <= ConversationLimits.lineBytes })
        #expect(month(lines.reduce(Data(), +))?.messages.first?.text.unicodeScalars.count == 200_000)
    }

    @Test func aMessageTooLargeToStoreWholeIsRefused() throws {
        #expect(throws: ConversationMessage.Invalid.self) { try message(text: String(repeating: "a", count: 4_194_305)) }
        // Under 4 MiB of text, but with long escaped references it needs more than 64 lines of 512 KiB.
        let wide = try (0..<64).map { _ in try ConversationMessage.Reference(kind: .op, id: .string(String(repeating: "\u{01}", count: 1024))) }
        #expect(throws: ConversationMessage.Invalid.self) {
            try message(text: String(repeating: "\u{01}", count: 2_000_000), references: wide).lines()
        }
    }

    @Test func fieldRulesFollowTheSchema() throws {
        #expect(throws: ConversationMessage.Invalid.self) { try message(at: "2026-02-30T12:00:00Z") }
        #expect(throws: ConversationMessage.Invalid.self) { try message(at: "2026-10-16T24:00:00Z") }
        #expect(throws: ConversationMessage.Invalid.self) {
            try ConversationMessage(id: Self.request.replacingOccurrences(of: "-7000-", with: "-4000-"), turn: Self.turn,
                                    at: "2026-10-16T12:00:00Z", speaker: .person, origin: .app, text: "x",
                                    device: "device-example", requestID: Self.request)
        }
        #expect(throws: ConversationMessage.Invalid.self) {
            try ConversationMessage(id: Self.request, turn: Self.turn, at: "2026-10-16T12:00:00Z", speaker: .person,
                                    origin: .app, text: "x", device: "device-example")
        }
        #expect(throws: ConversationMessage.Invalid.self) {
            try ConversationMessage(id: Self.request, turn: Self.turn, at: "2026-10-16T12:00:00Z", speaker: .backOffice,
                                    origin: .runtime, text: "x")
        }
        #expect(throws: ConversationMessage.Invalid.self) { try ConversationMessage.Reference(kind: .op, id: .number(JSONNumber(text: "7"))) }
        #expect(throws: ConversationMessage.Invalid.self) { try ConversationMessage.Reference(kind: .document, id: .number(JSONNumber(text: "0"))) }
    }

    @Test func aDocumentReferenceKeepsItsJSONType() throws {
        let number = try ConversationMessage.Reference(kind: .document, id: .number(JSONNumber(text: "7")))
        let string = try ConversationMessage.Reference(kind: .document, id: .string("7"))
        let read = try #require(month(try bytes([message(1, references: [number]), message(2, references: [string])])))
        #expect(read.messages.map { $0.references[0].id } == [.number(JSONNumber(text: "7")), .string("7")])
    }

    // MARK: - Damaged history

    func line(_ json: String) -> Data { Data((json + "\n").utf8) }

    @Test func aMissingPartIsDamageNeverAPrefix() throws {
        let lines = try message(text: String(repeating: "a", count: 200_000)).lines()
        #expect(lines.count == 4)
        let read = try #require(month(lines[0] + lines[1] + lines[3]))
        #expect(read.messages == [])
        #expect(read.damage.map(\.reason) == [.missingPart])
        #expect(read.damage.first?.lines == 1...3)
    }

    @Test func anInterleavedMessageBreaksTheGroup() throws {
        let long = try message(1, text: String(repeating: "a", count: 100_000)).lines()
        let short = try message(2).lines()
        let read = try #require(month(long[0] + short[0] + long[1]))
        #expect(read.messages.map(\.id) == [try message(2).id])
        #expect(read.damage.map(\.reason) == [.missingPart, .reusedID])
    }

    @Test func duplicatePartsAndMixedMetadataAreDamage() throws {
        let lines = try message(text: String(repeating: "a", count: 100_000)).lines()
        #expect(month(lines[0] + lines[0] + lines[1])?.damage.map(\.reason) == [.duplicatePart, .reusedID])
        let changed = Data(String(decoding: lines[1], as: UTF8.self).replacingOccurrences(of: "device-example", with: "device-other").utf8)
        #expect(month(lines[0] + changed)?.damage.map(\.reason) == [.mixedMetadata])
    }

    @Test func aReusedIDIsDamageAndTheFirstMessageStays() throws {
        let first = try message(1, text: "first")
        let second = try message(1, text: "second")
        let read = try #require(month(try bytes([first, second])))
        #expect(read.messages == [first])
        #expect(read.damage == [ConversationHistory.Damage(lines: 2...2, reason: .reusedID)])
    }

    @Test func aTornLastLineIsReportedAndEarlierMessagesStay() throws {
        let whole = try bytes([message(1)])
        let torn = try message(2).lines()[0].dropLast(5)
        let read = try #require(month(whole + torn))
        #expect(read.messages.count == 1)
        #expect(read.damage == [ConversationHistory.Damage(lines: 2...2, reason: .torn)])
    }

    @Test func invalidRecordsAreDamage() throws {
        let good = try message().lines()[0]
        let text = String(decoding: good, as: UTF8.self).dropLast()
        let duplicateKey = line(text.replacingOccurrences(of: #""format_version":"0","#, with: #""format_version":"0","format_version":"0","#))
        let wrongKind = line(text.replacingOccurrences(of: #""speaker":"person""#, with: #""speaker":"system""#))
        let bomb = line(String(repeating: "[", count: 200) + String(repeating: "]", count: 200))
        let huge = Data(repeating: 0x20, count: ConversationLimits.lineBytes + 1) + Data([0x0A])
        let notUTF8 = Data([0xFF, 0x0A])
        let read = try #require(month(duplicateKey + wrongKind + bomb + huge + notUTF8 + line("") + good))
        #expect(read.messages.count == 1)
        #expect(read.damage.map(\.reason) == Array(repeating: .invalidRecord, count: 6))
    }

    @Test func aMessageFromAnotherMonthIsDamage() throws {
        let read = try #require(month(try bytes([message(at: "2026-11-01T00:00:01Z")])))
        #expect(read.damage.map(\.reason) == [.wrongMonth])
    }

    @Test func aNewlineInTextIsNotASecondRecord() throws {
        let original = try message(text: "line one\n{\"format_version\":\"0\"}\nline three")
        let data = try original.lines().reduce(Data(), +)
        #expect(data.filter { $0 == 0x0A }.count == 1)
        #expect(month(data)?.messages == [original])
    }

    @Test func aWriterAppendsAfterCompleteMessagesOnly() throws {
        let whole = try bytes([message(1)])
        let long = try message(2, text: String(repeating: "a", count: 200_000)).lines()
        #expect(ConversationHistory.intactLength(of: whole) == whole.count)
        #expect(ConversationHistory.intactLength(of: whole + long[0] + long[1]) == whole.count)
        #expect(ConversationHistory.intactLength(of: whole + long[0] + long[1].dropLast(3)) == whole.count)
        #expect(ConversationHistory.intactLength(of: whole + long.reduce(Data(), +)) == whole.count + long.reduce(0) { $0 + $1.count })
        // A complete damaged line is left in place for repair; only a crash's tail is cut.
        let damaged = whole + line("not json") + long[0]
        #expect(ConversationHistory.intactLength(of: damaged) == whole.count + line("not json").count)
        #expect(ConversationHistory.intactLength(of: whole + line("not json")) == whole.count + line("not json").count)
        #expect(ConversationHistory.intactLength(of: Data("torn".utf8)) == 0)
    }

    @Test func tooManyLinesAreRefusedBeforeParsing() {
        let data = Data(repeating: 0x0A, count: ConversationLimits.monthLines + 1)
        #expect(ConversationHistory.read(data, month: "2026-10") == .refused("more than 200,000 lines"))
    }

    // MARK: - Files

    @Test func readsAMonthFromItsFileAndListsMonths() throws {
        let folder = try binder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dir = folder.appendingPathComponent(".sprava/conversation")
        try bytes([message()]).write(to: dir.appendingPathComponent("2026-10.ndjson"))
        try Data().write(to: dir.appendingPathComponent("2026-09.ndjson"))
        try Data().write(to: dir.appendingPathComponent("notes.ndjson"))
        try Data().write(to: dir.appendingPathComponent("2026-13.ndjson"))
        #expect(ConversationHistory.months(in: folder) == ["2026-09", "2026-10"])
        guard case .month(let read) = ConversationHistory.read(month: "2026-10", in: folder) else { Issue.record("not read"); return }
        #expect(read.messages == [try message()])
        #expect(ConversationHistory.read(month: "2025-01", in: folder) == .month(.init(month: "2025-01", messages: [], damage: [])))
        #expect(ConversationHistory.read(month: "../x", in: folder) == .refused("not a month"))
    }

    @Test func anOversizedMonthFileIsRefusedWithoutReadingIt() throws {
        let folder = try binder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(".sprava/conversation/2026-10.ndjson")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let fd = open(url.path, O_WRONLY)
        #expect(ftruncate(fd, off_t(ConversationLimits.monthFileBytes + 1)) == 0)
        close(fd)
        guard case .refused = ConversationHistory.read(month: "2026-10", in: folder) else { Issue.record("read an oversized file"); return }
    }

    @Test func aLinkOrASpecialFileIsRefusedWithoutWaiting() throws {
        let folder = try binder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dir = folder.appendingPathComponent(".sprava/conversation")
        let outside = folder.appendingPathComponent("outside.ndjson")
        try bytes([message()]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("2026-10.ndjson"), withDestinationURL: outside)
        guard case .refused = ConversationHistory.read(month: "2026-10", in: folder) else { Issue.record("followed a link"); return }
        #expect(mkfifo(dir.appendingPathComponent("2026-09.ndjson").path, 0o600) == 0)
        guard case .refused = ConversationHistory.read(month: "2026-09", in: folder) else { Issue.record("read a FIFO"); return }
        // A linked history folder is refused too.
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: folder.appendingPathComponent("elsewhere"))
        guard case .refused = ConversationHistory.read(month: "2026-10", in: folder) else { Issue.record("followed a linked folder"); return }
        #expect(ConversationHistory.months(in: folder) == [])
    }
}
