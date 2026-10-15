import Foundation
import Testing
@testable import Companion
import SpravaKit

private let viewBinder = CompanionWire.base64(Data(repeating: 41, count: 16))
private func n(_ value: Int64) -> JSONValue { .number(JSONNumber(text: String(value))) }
private func o(_ fields: [(key: String, value: JSONValue)]) -> JSONValue { .object(JSONObject(fields)) }
private func reading(_ items: [JSONValue], closed: [JSONValue] = [], docs: [JSONValue] = [],
                     buckets: [CompanionViewBucket: [JSONValue]] = [:]) -> CompanionViewReading {
    CompanionViewReading(name: "Sample binder", today: "2026-10-15", generatedAt: "2026-10-15T12:00:00Z",
        openItems: items, recentlyClosed: closed, documents: docs, buckets: buckets)
}
private func projected(_ value: CompanionProjectedView) throws -> JSONValue { try CompanionWire.parse(value.plaintext, limit: 778240) }

@Test func projectionKeepsJsonIdTypesAndUnicodeScalarsDistinctAndNormalizesLegacyFields() throws {
    let raw = o([("id", n(7)), ("title", .string("Inspect")), ("status", .string("unknown")), ("priority", .bool(true)),
        ("due", .string("20260705")), ("follow_up_at", .string("2026-W27-1")),
        ("tags", .array([.string("tag"), n(8)])), ("contexts", .bool(false))])
    let ids: [JSONValue] = [n(7), .string("7"), .string("é"), .string("e\u{301}")]
    let rows = [raw] + ids.dropFirst().map { o([("id", $0), ("title", .string("Other"))]) }
    let result = try CompanionViewProjection.project(binderID: viewBinder, version: 1,
        reading: reading(rows, docs: [o([("title", .string("Receipt")), ("date", .string("20260705")), ("content", .string("must not leave"))])],
                         buckets: [.today: ids + [n(99)]]))
    let payload = try projected(result), items = try #require(payload["items"]?.arrayValue)
    #expect(items.count == 4 && result.history.items.count == 4 && result.issues.isEmpty)
    #expect(items[0]["status"] == .string("open") && items[0]["priority"] == .null)
    #expect(items[0]["due"] == .string("2026-07-05") && items[0]["follow_up_at"] == .string("2026-06-29"))
    #expect(items[0]["tags"] == .array([.string("tag")]) && items[0]["contexts"] == .array([]))
    #expect(payload["buckets"]?["today"] == .array(ids))
    #expect(payload["documents"]?.arrayValue?.first?["content"] == nil)
}

@Test func duplicateAndInvalidIdsAreOmittedAcrossOpenAndClosedAndNeverKeepOldHashes() throws {
    let rows = [o([("id", .string("dup")), ("title", .string("A"))]),
                o([("id", .string("dup")), ("title", .string("B")), ("dismissed", .bool(true))]),
                o([("id", n(0)), ("title", .string("Invalid"))]), o([("id", n(-9)), ("title", .string("Negative"))])]
    let closed = [o([("id", n(-9)), ("title", .string("Closed")), ("action", .string("done"))])]
    let first = try CompanionViewProjection.project(binderID: viewBinder, version: 1, reading: reading(rows, closed: closed))
    #expect(try projected(first)["items"] == .array([]) && first.history.items.isEmpty)
    #expect(first.issues.filter { $0.reason == .duplicateID }.count == 2)
    #expect(first.issues.filter { $0.reason == .invalidID }.allSatisfy { $0.id == nil })
    let restored = try CompanionViewProjection.project(binderID: viewBinder, version: 2,
        reading: reading([rows[0]]), previous: first.history)
    #expect(restored.history.items.first?.changedIn == 2)
}

@Test func wholeRecordHashPreservesChangedInUntilAnUnpublishedFieldChanges() throws {
    let firstRow = o([("id", n(1)), ("title", .string("Inspect")), ("recurrence", .string("monthly")), ("extra", .bool(true))])
    let first = try CompanionViewProjection.project(binderID: viewBinder, version: 1, reading: reading([firstRow]))
    let reordered = o([("extra", .bool(true)), ("recurrence", .string("monthly")), ("title", .string("Inspect")), ("id", n(1))])
    let second = try CompanionViewProjection.project(binderID: viewBinder, version: 2, reading: reading([reordered]), previous: first.history)
    #expect(second.history.items.first?.changedIn == 1 && second.history.items.first?.hash == first.history.items.first?.hash)
    let changed = o([("id", n(1)), ("title", .string("Inspect")), ("recurrence", .string("weekly")), ("extra", .bool(true))])
    let third = try CompanionViewProjection.project(binderID: viewBinder, version: 3, reading: reading([changed]), previous: second.history)
    #expect(third.history.items.first?.changedIn == 3 && third.history.items.first?.hash != second.history.items.first?.hash)
    #expect(try projected(third)["items"]?.arrayValue?.first?["recurrence"] == nil)
    let other = CompanionWire.base64(Data(repeating: 42, count: 16))
    #expect(throws: CompanionViewProjectionError.invalid) {
        try CompanionViewProjection.project(binderID: other, version: 4, reading: reading([changed]), previous: third.history)
    }
}

@Test func dismissedItemsStayHiddenAndLegacyDoneItemsFollowTheOrderedNormalizedClosures() throws {
    let rows = [o([("id", n(1)), ("title", .string("Hidden")), ("dismissed", .bool(true))]),
                o([("id", n(2)), ("title", .string("Legacy done")), ("status", .string("done"))])]
    let closed = [o([("id", n(3)), ("title", .bool(false)), ("action", .string("dropped")),
                      ("closed_at", .string("2026-10-15T14:04:03.123+02:00"))]),
                  o([("id", n(4)), ("title", .string("Not a closure")), ("action", .string("edited"))])]
    let result = try CompanionViewProjection.project(binderID: viewBinder, version: 1, reading: reading(rows, closed: closed, buckets: [.today: [n(1), n(2)]]))
    let payload = try projected(result), closures = try #require(payload["closed"]?.arrayValue)
    #expect(payload["items"] == .array([]) && payload["buckets"]?["today"] == .array([]))
    #expect(result.history.items.count == 2 && closures.count == 2)
    #expect(closures[0]["id"] == n(3) && closures[0]["title"] == .string("") && closures[0]["closed_at"] == .string("2026-10-15T12:04:03Z"))
    #expect(closures[1]["id"] == n(2) && closures[1]["closed_at"] == .null)
}

@Test func oversizedNotesAreOmittedTogetherButTheirOriginalRecordsStillDriveConflicts() throws {
    let row = o([("id", n(1)), ("title", .string("Inspect")), ("notes", .string(String(repeating: "n", count: 780000)))])
    let result = try CompanionViewProjection.project(binderID: viewBinder, version: 1, reading: reading([row]))
    let payload = try projected(result)
    #expect(result.notesOmitted && payload["notes_omitted"] == .bool(true) && payload["items"]?.arrayValue?.first?["notes"] == .null)
    #expect(result.history.items.first?.hash == (try Canonical.hash(row)))
    let tooLarge = o([("id", n(1)), ("title", .string(String(repeating: "t", count: 780000)))])
    #expect(throws: CompanionViewProjectionError.tooLarge) {
        try CompanionViewProjection.project(binderID: viewBinder, version: 2, reading: reading([tooLarge]))
    }
}

@Test func ambiguousObjectKeysAndNonfiniteRecordsCannotKeepAConflictHashAndDeepInputIsBounded() throws {
    let duplicate = o([("id", n(1)), ("title", .string("A")), ("title", .string("B"))])
    let nonfinite = o([("id", n(2)), ("title", .string("A")), ("unknown", .number(JSONNumber(text: "1e999")))])
    let result = try CompanionViewProjection.project(binderID: viewBinder, version: 1, reading: reading([duplicate, nonfinite]))
    #expect(result.history.items.isEmpty && result.issues.count == 2)
    #expect(try projected(result)["items"] == .array([]))
    var deep = JSONValue.null
    for _ in 0..<66 { deep = .array([deep]) }
    #expect(throws: CompanionViewProjectionError.tooLarge) {
        try CompanionViewProjection.project(binderID: viewBinder, version: 1, reading: reading([o([("id", n(3)), ("title", .string("A")), ("unknown", deep)])]))
    }
}
