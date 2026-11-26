import BinderFormat
import SpravaKit
import Testing

@Suite struct PersonPageReadingTests {
    @Test func typedTextAndReadMarksAreBoundToARevisionAndPage() throws {
        let hash = String(repeating: "a", count: 64)
        let typed = try #require(PersonPageReading(revision: hash, page: 3, text: "Water the seedlings on Friday."))
        let mark = try #require(PersonPageReading(revision: hash, page: 4, text: ""))
        #expect(typed.searchable && !mark.searchable)
        #expect(PersonPageReading.list(in: .obj([(PersonPageReading.catalogField, .array([typed.json, mark.json]))])) == [typed, mark])
        #expect(PersonPageReading.list(in: .obj([(PersonPageReading.catalogField, .array([typed.json, typed.json]))])) == nil)
        #expect(PersonPageReading(revision: hash, page: 0, text: "") == nil)
        #expect(PersonPageReading(revision: hash, page: 1, text: String(repeating: "x", count: 16_385)) == nil)
    }
}
