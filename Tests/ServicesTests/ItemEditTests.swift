import BinderFormat
import BinderStore
import CaptureTestSupport
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

@Suite struct ItemEditTests {
    func edit(_ s: PSetup, _ args: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([
            ("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("edit_item")),
            ("args", .obj([("id", .str("board-1"))] + args)),
        ])), now: pNow, today: today)).value
    }

    @Test func textAndWaitingStateAreSavedTogether() throws {
        let s = try pSetup()
        try bAddItem(s, id: "board-1", title: "Review an invented maintenance quote")
        let result = try edit(s, [("set", .obj([("details", .str("Compare the two invented proposals")), ("priority", .str("high"))])),
                                  ("status", .str("waiting")), ("waiting_on", .str("the contractor")),
                                  ("follow_up_at", .str("2026-11-12"))])
        #expect(result["ok"] == .bool(true), "\(result)")
        let item = try #require(Teka.read(s.folder).items.first { $0.idText == "board-1" })
        #expect(item.priority == .high && item.status == .waiting)
        #expect(item.waitingOn == "the contractor" && item.followUpAt?.description == "2026-11-12")
        #expect(item.object?["details"] == .str("Compare the two invented proposals"))
        #expect(try edit(s, [("status", .str("open"))])["ok"] == .bool(true))
        let reopened = try #require(Teka.read(s.folder).items.first { $0.idText == "board-1" })
        #expect(reopened.status == .open && reopened.waitingOn == nil && reopened.followUpAt == nil)
        #expect(reopened.priority == .high && reopened.object?["details"] == item.object?["details"])
    }

    @Test func anInvalidSecondOperationDoesNotSaveTheFirst() throws {
        let s = try pSetup()
        try bAddItem(s, id: "board-1", title: "Review the invented minutes")
        let before = try Data(contentsOf: s.folder.appendingPathComponent("catalog.json"))
        let ops = try TekaStore(folder: s.folder).readOpLog().ops.count
        let result = try edit(s, [("set", .obj([("title", .str("This must not be saved"))])), ("status", .str("done"))])
        #expect(result["ok"] == .bool(false))
        #expect(try Data(contentsOf: s.folder.appendingPathComponent("catalog.json")) == before)
        #expect(try TekaStore(folder: s.folder).readOpLog().ops.count == ops)
    }

    @Test func theEditorCannotChangePrivacyOrWriteAnotherOwnersBinder() throws {
        let s = try pSetup()
        try bAddItem(s, id: "board-1", title: "Review the invented minutes")
        #expect(try edit(s, [("set", .obj([("redact", .bool(false))]))])["ok"] == .bool(false))
        let owner = s.folder.appendingPathComponent(".sprava/owner.json")
        try Data(#"{"device":"another-invented-device"}"#.utf8).write(to: owner)
        #expect(try edit(s, [("set", .obj([("title", .str("Must stay unchanged"))]))])["ok"] == .bool(false))
        #expect(Teka.read(s.folder).items.first { $0.idText == "board-1" }?.title == "Review the invented minutes")
    }
}
