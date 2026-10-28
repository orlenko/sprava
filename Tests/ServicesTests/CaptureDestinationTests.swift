import BinderStore
import Capture
import Foundation
import Shelf
import SpravaKit
@testable import Services
import Testing

@Suite struct CaptureDestinationTests {
    @Test func onlyAListedBinderOwnedHereCanBeRecordedAsTheNotesDestination() throws {
        let (commands, folder) = try DirectAddTests().adopted()
        let shelf = ShelfStore(supportDirectory: commands.support)
        try shelf.add(folder)
        let fields: [(String, JSONValue)] = [("command", .str("capture_notice")), ("binder", .str(folder.path)),
            ("event", .str(UUID().uuidString.lowercased())), ("sha256", .str("sha256:" + String(repeating: "a", count: 64)))]
        let request = JSONWriter.compact(.obj(fields))
        let accepted = try JSONParser.parse(commands.handle(request)).value
        #expect(accepted["ok"] == .bool(true), "Invented destination was refused: \(accepted["error"]?.stringValue ?? "unknown")")
        let anotherMac = Commands(support: commands.support, deviceID: "another-invented-mac")
        #expect(try JSONParser.parse(anotherMac.handle(request)).value["ok"] == .bool(false))
        try shelf.remove(folder)
        #expect(try JSONParser.parse(commands.handle(request)).value["ok"] == .bool(false))
    }
}
