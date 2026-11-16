import BinderFormat
import BinderStore
import Foundation
@testable import Services
import SpravaKit
import Testing

/// The binder's instructions through the command table (decisions.md D43; docs/binder-instructions.md §3). Invented data only.
@Suite(.serialized) struct InstructionsCommandTests {
    func req(_ c: Commands, _ pairs: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(pairs)))).value
    }

    /// An adopted binder and the commands that write it.
    func binder() throws -> (URL, Commands) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-instructions-\(UUID().uuidString)")
        let f = root.appendingPathComponent("household", isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try Data(#"{"meta":{"schema_version":2,"name":"household"},"documents":[],"open_items":[],"processing_log":[]}"#.utf8)
            .write(to: f.appendingPathComponent("catalog.json"))
        let c = Commands(support: root.appendingPathComponent("support"), deviceID: "dev")
        #expect(try req(c, [("command", .str("adopt")), ("binder", .string(f.path))])["ok"] == .bool(true))
        return (f, c)
    }

    @Test func savedThenUndone() throws {
        let (f, c) = try binder()
        let saved = try req(c, [("command", .str("save_instructions")), ("binder", .string(f.path)),
                                ("text", .str("Bills go in bills.\n")), ("expected", .string(BinderInstructions.digest("")))])
        #expect(saved["ok"] == .bool(true), "\(saved)")
        #expect(saved["digest"] == .string(BinderInstructions.digest("Bills go in bills.\n")))
        #expect(try BinderInstructions.read(f).get().isAccepted)
        let undone = try req(c, [("command", .str("undo_instructions")), ("binder", .string(f.path))])
        #expect(undone["ok"] == .bool(true), "\(undone)")
        #expect(try BinderInstructions.read(f).get().text == "")
    }

    @Test func aStaleSaveSaysSoInPlainWords() throws {
        let (f, c) = try binder()
        try Data("Kept by hand.\n".utf8).write(to: f.appendingPathComponent("AGENTS.md"))
        let refused = try req(c, [("command", .str("save_instructions")), ("binder", .string(f.path)),
                                  ("text", .str("Mine.\n")), ("expected", .string(BinderInstructions.digest("")))])
        #expect(refused["ok"] == .bool(false))
        #expect(refused["error"]?.stringValue?.hasPrefix("AGENTS.md changed since this page read it") == true)
        #expect(try String(contentsOf: f.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "Kept by hand.\n")
    }

    @Test func anotherMacsBinderIsNotWritten() throws {
        let (f, _) = try binder()
        let other = Commands(support: f.deletingLastPathComponent().appendingPathComponent("other-support"), deviceID: "another-mac")
        let refused = try req(other, [("command", .str("save_instructions")), ("binder", .string(f.path)),
                                      ("text", .str("Mine.\n")), ("expected", .string(BinderInstructions.digest("")))])
        #expect(refused["ok"] == .bool(false))
        #expect(!FileManager.default.fileExists(atPath: f.appendingPathComponent("AGENTS.md").path))
    }

    @Test func theConversationSeesAGENTSmdChange() throws {
        let (f, _) = try binder()
        let before = ClaudeConversationPolicy.revision(of: f)
        #expect(before?.hasSuffix("; AGENTS.md revision none") == true)
        try Data("Bills go in bills.\n".utf8).write(to: f.appendingPathComponent("AGENTS.md"))
        let after = ClaudeConversationPolicy.revision(of: f)
        #expect(after != before && after?.contains("AGENTS.md revision none") == false)
    }
}
