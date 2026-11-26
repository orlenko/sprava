import BinderFormat
import CaptureTestSupport
import Foundation
import SpravaKit
import Testing
@testable import Services

@Suite struct PageReadingMarksTests {
    @Test func theCoverageListGetsOnlyPageNumbersAndWhetherTheyCanBeSearched() throws {
        let setup = try pSetup()
        let doc = try #require(Teka.read(setup.folder).catalog?["documents"]?.arrayValue?.first)
        let id = try #require(doc["id"]), path = try #require(doc["path"]?.stringValue)
        let file = setup.folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Invented page image".utf8).write(to: file)
        let rev = try #require(DocumentPaths.sha256(of: file))
        let fields: [(String, JSONValue)] = [("binder", .str(setup.folder.path)), ("document_id", id), ("path", .str(path)), ("revision", .str(rev))]
        func call(_ name: String, _ extra: [(String, JSONValue)]) throws -> JSONValue {
            try JSONParser.parse(setup.commands.handle(JSONWriter.compact(.obj(fields + [("command", .str(name))] + extra)))).value
        }
        #expect(try call("save_page_reading", [("page", .int(3)), ("expected", .null), ("text", .str("Invented garden rule."))])["ok"] == .bool(true))
        #expect(try call("page_reading", [])["marks"] == .array([.obj([("page", .int(3)), ("searchable", .bool(true))])]))
        #expect(try call("page_reading", [("page", .int(3))])["text"] == .str("Invented garden rule."))
    }
}
