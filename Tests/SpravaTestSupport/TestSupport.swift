import Foundation
import SpravaKit

// What several test targets share: the invented fixtures, a binder made from one, and the fixed days and times
// the tests use.

/// The bundle that holds `Fixtures/`. (A test-support target does not import Testing, so `swift build` builds it
/// without the testing macros.)
package enum TestFixtures {
    package static let bundle = Bundle.module
}

/// Copies an invented fixture into a temporary folder named like a binder, so reading has a real folder.
package func makeTeka(fixture: String, folderName: String? = nil, subdirectory: String? = nil,
                      mutate: ((URL) throws -> Void)? = nil) throws -> URL {
    guard let source = Bundle.module.url(forResource: fixture, withExtension: "json",
                                         subdirectory: subdirectory.map { "Fixtures/\($0)" } ?? "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    let data = try Data(contentsOf: source)
    let parsedName = try JSONParser.parse(data).value["meta"]?["name"]?.stringValue
    let name = folderName ?? parsedName ?? "teka"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-tests-\(UUID().uuidString)")
    let folder = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try data.write(to: folder.appendingPathComponent("catalog.json"))
    try mutate?(folder)
    return folder
}

package let today = CalendarDate(year: 2026, month: 10, day: 7)!
package let utc = TimeZone(identifier: "UTC")!

package let pNow = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-06 (Tue) in UTC-4 morning

package func item(_ quote: String, _ title: String, _ action: String = "other", when: String = "", people: [String] = [], amount: String = "") -> JSONValue {
    .obj([("quote", .string(quote)), ("title", .string(title)), ("action", .string(action)), ("when_text", .string(when)),
          ("people", .array(people.map(JSONValue.string))), ("amount_text", .string(amount))])
}
