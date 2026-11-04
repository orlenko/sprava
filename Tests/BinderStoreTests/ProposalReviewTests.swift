import BinderStore
import Foundation
import SpravaKit
import Testing

/// What a review card says first: the document, what its button does, and each warning once.
@Suite struct ProposalReviewTests {
    private let actor = JSONObject([(key: "kind", value: .str("clerk"))])

    private func file(_ name: String, kind: String? = nil, title: String = "Invented notice", date: String? = nil) -> JSONObject {
        var document = JSONObject([(key: "id", value: .str("$new:1")), (key: "title", value: .string(title)),
                                   (key: "path", value: .string("Letters/" + name))])
        if let kind { document.set("kind", .string(kind)) }
        if let date { document.set("date", .string(date)) }
        return JSONObject([(key: "op", value: .str("file_document")),
                           (key: "args", value: .obj([("document", .object(document)), ("from", .string("intake/" + name))]))])
    }

    private func todo(_ title: String, due: String? = nil, flags: [String] = []) -> JSONObject {
        var item = JSONObject([(key: "title", value: .string(title))])
        if let due { item.set("due", .string(due)) }
        var op = JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .object(item))]))])
        if !flags.isEmpty { op.set("card", .obj([("flags", .array(flags.map(JSONValue.string)))])) }
        return op
    }

    private func review(_ ops: [JSONObject], provenance: JSONObject? = nil, changed: [String] = []) -> JSONObject {
        Proposal.make(title: "Invented card", actor: actor, ops: ops, provenance: provenance)
            .review(describe: { $0["op"]?.stringValue ?? "?" }, changed: changed)
    }

    private func strings(_ v: JSONValue?) -> [String] { v?.arrayValue?.compactMap(\.stringValue) ?? [] }

    @Test func aFilingCardNamesTheFilesWhereTheyAreNowNotWhereTheyGo() {
        let intake = JSONObject([(key: "obtained", value: .obj([("from", .str("Invented Landlord"))])),
                                 (key: "preview", value: .str("Dear tenant"))])
        let out = review([file("a.eml", kind: "email", title: "Rent notice", date: "2026-03-04"), file("b.pdf", kind: "attachment", title: "Other"),
                          todo("Pay the invented rent", due: "2026-04-01")],
                         provenance: JSONObject([(key: "intake", value: .object(intake))]))
        #expect(out["kind"] == .str("filing"))
        #expect(out["heading"] == .str("Rent notice"))
        #expect(out["date"] == .str("2026-03-04"))
        #expect(out["sender"] == .str("Invented Landlord"))
        #expect(out["begins"] == .str("Dear tenant"))
        #expect(out["from_intake"] == .bool(true))
        #expect(out["files"]?.arrayValue?.compactMap { $0["path"]?.stringValue } == ["intake/a.eml", "intake/b.pdf"])
        let added = out["todos"]?.arrayValue?.first
        #expect(added?["index"] == .int(2))
        #expect(added?["title"] == .str("Pay the invented rent"))
        #expect(added?["due"] == .str("2026-04-01"))
    }

    @Test func missedItemsAreSaidOnceForTheCardAndNotOnEachItem() {
        let flag = Proposal.cappedFlag
        let ops = (0..<5).map { todo("Invented item \($0)", flags: [flag, "date taken from the sentence"]) }
        let p = Proposal.make(title: "Invented card", actor: actor, ops: ops)
        let out = p.review(describe: { _ in "" })
        #expect(strings(out["warnings"]).count { $0.contains("may have missed") } == 1)
        for item in out["todos"]?.arrayValue ?? [] {
            #expect(strings(item["notes"]) == ["date taken from the sentence"])
        }
        // The full record under Details says it once too.
        #expect(p.cardNotes.count { $0 == flag } == 1)
    }

    @Test func aHeldFileShowsItsReasonAndNothingThatLooksLikeAReading() {
        let intake = JSONObject([(key: "held", value: .str("it looks like a credential file")), (key: "preview", value: .str("should not show"))])
        let reading = JSONObject([(key: "summary", value: .str("should not show either"))])
        let out = review([file("a.txt")], provenance: JSONObject([(key: "intake", value: .object(intake)), (key: "reading", value: .object(reading))]))
        #expect(out["summary"] == nil)
        #expect(out["begins"] == nil)
        #expect(strings(out["warnings"]).contains { $0.contains("it looks like a credential file") })
    }

    @Test func theClerksSummaryComesBeforeTheFirstLines() {
        let intake = JSONObject([(key: "preview", value: .str("Dear tenant"))])
        let reading = JSONObject([(key: "summary", value: .str("An invented rent notice."))])
        let out = review([file("a.txt")], provenance: JSONObject([(key: "intake", value: .object(intake)), (key: "reading", value: .object(reading))]))
        #expect(out["summary"] == .str("An invented rent notice."))
        #expect(out["begins"] == nil)
    }

    @Test func aReasonThatOnlyDescribesTheDocumentIsNoWarningButAnyOtherIs() {
        func warned(_ reason: String) -> Bool {
            let out = review([todo("Invented")], provenance: JSONObject([(key: "escalate", value: .array([.string(reason)]))]))
            return strings(out["warnings"]).contains { $0.contains("may have missed") }
        }
        #expect(!warned("it is long"))
        #expect(!warned("it sets rules or obligations"))
        #expect(!warned("the clerk is not sure what it is"))
        #expect(warned("parts of it ask for something the clerk did not list"))
        #expect(warned("a reason nobody has written yet"))
    }

    @Test func whatWasLeftOutOrKeptElsewhereOrUnreadStaysInFrontOfThePerson() {
        let intake = JSONObject([(key: "notes", value: .array([.str("attachment \u{201C}x.zip\u{201D} was not read: too large")])),
                                 (key: "mismatch", value: .bool(true)), (key: "text_from", value: .str("ocr"))])
        let provenance = JSONObject([(key: "intake", value: .object(intake)), (key: "left_out", value: .array([.str("Water the invented fern")])),
                                     (key: "remains", value: .str("the invented phone"))])
        let warnings = strings(review([file("a.pdf")], provenance: provenance, changed: ["Invented item"])["warnings"])
        for words in ["Invented item", "Water the invented fern", "the invented phone", "x.zip", "contents another", "from a scan"] {
            #expect(warnings.contains { $0.contains(words) }, "\(words)")
        }
        #expect(warnings.first?.contains("changed since") == true)
    }

    @Test func aChangeToAnExistingItemIsAChangeNeverAFile() {
        let change = JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", .str("i-1"))]))])
        let record = JSONObject([(key: "op", value: .str("file_document")), (key: "args", value: .obj([("document", .obj([("path", .str("a.pdf"))]))]))])
        let out = review([change, record])
        #expect(out["kind"] == .str("change"))
        #expect(out["files"]?.arrayValue?.isEmpty == true)
        #expect(out["changes"]?.arrayValue?.compactMap { $0["line"]?.stringValue } == ["update_item", "file_document"])
    }

    @Test func aCardThatCannotBeAppliedIsManual() {
        #expect(review([])["kind"] == .str("manual"))
        let change = JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", .str("i-1"))]))])
        #expect(review([change], provenance: JSONObject([(key: "manual_repair", value: .bool(true))]))["kind"] == .str("manual"))
    }
}
