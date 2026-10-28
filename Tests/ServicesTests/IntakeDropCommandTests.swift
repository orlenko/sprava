import BinderStore
import Capture
import Darwin
import Foundation
@testable import Services
import SpravaKit
import Testing

@Suite struct IntakeDropCommandTests {
    static func handle(_ text: String) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-drop-source-" + UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return try FileHandle(forReadingFrom: url)
    }
    static func request(_ folder: URL, _ name: String = "Invented letter.pdf") -> String {
        JSONWriter.compact(.obj([("command", .str("intake_drop")), ("binder", .str(folder.path)), ("name", .str(name))]))
    }

    @Test func anAdoptedListedBinderOfThisMacTakesTheDroppedFileIntoIntake() throws {
        let (commands, folder) = try DirectAddTests().adopted()
        let answer = try JSONParser.parse(commands.dropIntake(Self.request(folder), file: try Self.handle("Invented letter"), listed: { _ in true })).value
        #expect(answer["ok"] == .bool(true)); #expect(answer["path"] == .str("intake/Invented letter.pdf"))
        #expect(IntakeWatcher.candidates(in: folder).contains { $0.name == "Invented letter.pdf" })
    }

    @Test func aBinderOffTheShelfOrNotThisMacsOrAMalformedRequestTakesNothing() throws {
        let (commands, folder) = try DirectAddTests().adopted()
        let unlisted = try JSONParser.parse(commands.dropIntake(Self.request(folder), file: try Self.handle("Invented"), listed: { _ in false })).value
        #expect(unlisted["ok"] == .bool(false))
        let elsewhere = Commands(support: commands.support, deviceID: "another-mac")
        #expect(try JSONParser.parse(elsewhere.dropIntake(Self.request(folder), file: try Self.handle("Invented"), listed: { _ in true })).value["ok"] == .bool(false))
        let wrong = JSONWriter.compact(.obj([("command", .str("apply")), ("binder", .str(folder.path)), ("name", .str("x"))]))
        #expect(try JSONParser.parse(commands.dropIntake(wrong, file: try Self.handle("Invented"), listed: { _ in true })).value["ok"] == .bool(false))
        #expect(IntakeWatcher.candidates(in: folder).isEmpty)
    }
}
