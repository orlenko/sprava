import BinderFormat
import Darwin
import Foundation
@testable import Hub
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

// Regression tests for the Bugbot review of the ops layer (privacy ratchet, hub lane, proposals, store, guard,
// adoption). Invented data only.

@Suite(.serialized) struct BugbotOpsTests {
    @Test func collidingBinderNamesAreFound() throws {   // qewBo
        let a = try makeTeka(fixture: "lifeproj-v1-legacy", folderName: "tax-2026")
        let b = try makeTeka(fixture: "lifeproj-v1-legacy", folderName: "Tax-2026") { f in
            let url = f.appendingPathComponent("catalog.json")
            let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\"tax-2026\"", with: "\"Tax-2026\"")
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let other = try makeTeka(fixture: "lifeproj-v2-live")
        let rows = Shelf.rows(registry: nil, picked: [a, b, other])
        let colliding = HubLane.collidingFolders(rows, today: today)
        #expect(colliding == [a.standardizedFileURL.path, b.standardizedFileURL.path])
        // A former name another binder still drains under counts too.
        let renamed = try makeTeka(fixture: "lifeproj-v2-fresh", folderName: "estate-renamed") { f in
            let url = f.appendingPathComponent("catalog.json")
            var cat = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
            var meta = cat["meta"]?.objectValue ?? JSONObject()
            meta.set("name", .str("estate-renamed"))
            meta.set("former_names", .array([.obj([("name", .str("Rental-Elm-Street")), ("until", .str("2027-01-01"))])]))
            cat.set("meta", .object(meta))
            try Data(JSONWriter.pretty(.object(cat)).utf8).write(to: url)
        }
        #expect(HubLane.collidingFolders(Shelf.rows(registry: nil, picked: [other, renamed]), today: today).count == 2)
    }
}
