import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Repeating to-dos (binder-v0 §5.4): the date rule, Done that moves a series on once, the person setting and removing
/// a repeat, and Undo. Invented data only.
@Suite(.serialized) struct RecurrenceTests {
    let user = JSONObject([(key: "kind", value: .str("user"))])
    /// The fixture's `estate-example-2026-010` repeats monthly on the 14th and is due 2026-11-14.
    let monthly = JSONValue.str("estate-example-2026-010")

    func date(_ text: String) -> CalendarDate { CalendarDate.strict(text)! }
    func noon(_ day: String) -> Date { Timestamp.parse(day + "T12:00:00Z")! }

    // MARK: next_after

    @Test func monthlyFallsOnItsDayStrictlyAfter() {
        let rule = Recurrence.Rule.monthly(day: 15)
        #expect(Recurrence.nextAfter(date("2026-11-14"), rule) == date("2026-11-15"))
        #expect(Recurrence.nextAfter(date("2026-11-15"), rule) == date("2026-12-15"))
        #expect(Recurrence.nextAfter(date("2026-12-15"), rule) == date("2027-01-15"))
    }

    @Test func aDayTheMonthLacksFallsOnItsLastDay() {
        let rule = Recurrence.Rule.monthly(day: 31)
        #expect(Recurrence.nextAfter(date("2027-01-31"), rule) == date("2027-02-28"))
        #expect(Recurrence.nextAfter(date("2028-01-31"), rule) == date("2028-02-29"))
        #expect(Recurrence.nextAfter(date("2027-02-28"), rule) == date("2027-03-31"))
        #expect(Recurrence.nextAfter(date("2027-03-31"), rule) == date("2027-04-30"))
        // A clamped month never pulls later months short.
        #expect(Recurrence.nextAfter(date("2027-04-30"), rule) == date("2027-05-31"))
    }

    @Test func yearlyFallsOnItsMonthAndDay() {
        #expect(Recurrence.nextAfter(date("2026-07-29"), .yearly(month: 7, day: 30)) == date("2026-07-30"))
        #expect(Recurrence.nextAfter(date("2026-07-30"), .yearly(month: 7, day: 30)) == date("2027-07-30"))
        let leap = Recurrence.Rule.yearly(month: 2, day: 29)
        #expect(Recurrence.nextAfter(date("2027-01-01"), leap) == date("2027-02-28"))
        #expect(Recurrence.nextAfter(date("2027-02-28"), leap) == date("2028-02-29"))
    }

    @Test func aLateCompletionNeverLandsInThePast() {
        let rule = Recurrence.Rule.monthly(day: 15)
        // Done on 20 November for the October occurrence: the next date is 15 December, not 15 November.
        #expect(Recurrence.nextDue(occurrence: date("2026-10-15"), today: date("2026-11-20"), rule) == date("2026-12-15"))
        // Done early: the next date follows the occurrence, not today.
        #expect(Recurrence.nextDue(occurrence: date("2026-11-15"), today: date("2026-11-02"), rule) == date("2026-12-15"))
        #expect(Recurrence.nextAfter(date("9999-12-15"), rule) == nil)
    }

    @Test func onlyWellFormedRulesAreRead() {
        func rule(_ text: String) -> Recurrence.Rule? { Recurrence.rule(try? JSONParser.parse(Data(text.utf8)).value) }
        #expect(rule(#"{"freq":"monthly","day":15}"#) == .monthly(day: 15))
        #expect(rule(#"{"freq":"monthly","day":15.0}"#) == .monthly(day: 15))
        #expect(rule(#"{"freq":"yearly","month":7,"day":30}"#) == .yearly(month: 7, day: 30))
        #expect(rule(#"{"freq":"monthly","day":15,"month":3}"#) == .monthly(day: 15))   // month is ignored when monthly
        for bad in [#"{"freq":"monthly","day":0}"#, #"{"freq":"monthly","day":32}"#, #"{"freq":"yearly","day":3}"#,
                    #"{"freq":"yearly","month":13,"day":3}"#, #"{"freq":"weekly","day":3}"#, #"{"freq":"monthly","day":1.5}"#,
                    #"{"freq":"monthly","day":"15"}"#, #"{"freq":"monthly","day":15,"month":0}"#, #""monthly""#] {
            #expect(rule(bad) == nil, "\(bad)")
        }
    }

    // MARK: Done in a binder

    func adopted(at now: Date) throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        store.repeatsRefusal = nil   // as the runtime sets it for a binder lifeproj cannot reach
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        return (folder, store)
    }

    func item(_ folder: URL, _ id: JSONValue) -> JSONValue? {
        Teka.read(folder).catalog?["open_items"]?.arrayValue?.first { $0["id"] == id }
    }

    func done(_ store: TekaStore, _ id: JSONValue, shown: String?, now: Date) throws -> [JSONObject] {
        var args = JSONObject([(key: "id", value: id)])
        if let shown { args.set("occurrence_due", .string(shown)) }
        return try store.apply([.init(op: "complete", args: args, actor: user)], now: now)
    }

    @Test func doneMovesTheItemToItsNextDateAndKeepsItOpen() throws {
        let now = noon("2026-11-10")
        let (folder, store) = try adopted(at: now)
        let applied = try done(store, monthly, shown: "2026-11-14", now: now)
        #expect(applied[0]["args"]?["next_due"] == .str("2026-12-14"))
        #expect(item(folder, monthly)?["due"] == .str("2026-12-14"))
        #expect(item(folder, monthly)?["status"] == .str("open"))
        let entry = Teka.read(folder).catalog?["processing_log"]?.arrayValue?.last
        #expect(entry?["action"] == .str("occurrence") && entry?["item"] == monthly && entry?["id"] == nil)
        #expect(entry?["due"] == .str("2026-11-14") && entry?["next_due"] == .str("2026-12-14"))
        _ = try Replay.run(try store.readOpLog().ops)
    }

    @Test func aLateDoneSkipsThePastDate() throws {
        let now = noon("2026-12-20")
        let (folder, store) = try adopted(at: now)
        _ = try done(store, monthly, shown: "2026-11-14", now: now)
        #expect(item(folder, monthly)?["due"] == .str("2027-01-14"))
    }

    @Test func theSameDoneTwiceMovesTheSeriesOnOnce() throws {
        let now = noon("2026-11-10")
        let (folder, store) = try adopted(at: now)
        _ = try done(store, monthly, shown: "2026-11-14", now: now)
        // A second window, or a phone's late request, that still showed 14 November.
        #expect(throws: TekaStore.Refused.self) { try done(store, monthly, shown: "2026-11-14", now: now) }
        // A Done that names no occurrence is refused too.
        #expect(throws: TekaStore.Refused.self) { try done(store, monthly, shown: nil, now: now) }
        #expect(item(folder, monthly)?["due"] == .str("2026-12-14"))
    }

    @Test func undoPutsTheDateBack() throws {
        let now = noon("2026-11-10")
        let (folder, store) = try adopted(at: now)
        let applied = try done(store, monthly, shown: "2026-11-14", now: now)
        try store.undo(opID: applied[0]["id"]!.stringValue!, now: now)
        #expect(item(folder, monthly)?["due"] == .str("2026-11-14"))
        #expect(item(folder, monthly)?["recurrence"] != nil)
        // The occurrence entry stays; the undo is recorded beside it (binder-v0 §6.10).
        #expect(Teka.read(folder).catalog?["processing_log"]?.arrayValue?.contains { $0["action"] == .str("occurrence") && $0["op_id"] == applied[0]["id"] } == true)
        _ = try Replay.run(try store.readOpLog().ops)
    }

    @Test func theThirtyFirstInFebruary() throws {
        let now = noon("2027-01-10")
        let (folder, store) = try adopted(at: now)
        let id = JSONValue.str("estate-example-2026-007")
        _ = try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: id), (key: "set", value: .obj([
            ("due", .str("2027-01-31")), ("recurrence", .obj([("freq", .str("monthly")), ("day", .int(31))]))]))]), actor: user)], now: now)
        _ = try done(store, id, shown: "2027-01-31", now: now)
        #expect(item(folder, id)?["due"] == .str("2027-02-28"))
        _ = try done(store, id, shown: "2027-02-28", now: now)
        #expect(item(folder, id)?["due"] == .str("2027-03-31"))
    }

    @Test func droppingASeriesEndsItAndUndoBringsItBackRepeating() throws {
        let now = noon("2026-11-10")
        let (folder, store) = try adopted(at: now)
        let dropped = try store.apply([.init(op: "drop", args: JSONObject([(key: "id", value: monthly)]), actor: user)], now: now)
        #expect(item(folder, monthly) == nil)
        try store.undo(opID: dropped[0]["id"]!.stringValue!, now: now)
        let back = Teka.read(folder).catalog?["open_items"]?.arrayValue?.first { $0["provenance"]?["reopened_from"] == monthly }
        #expect(back?["recurrence"] == .obj([("freq", .str("monthly")), ("day", .int(14))]))
        #expect(back?["due"] == .str("2026-11-14"))
    }

    @Test func aStoreNotToldThatRepeatsAreSafeWritesNone() throws {
        let now = noon("2026-11-10")
        let (folder, store) = try adopted(at: now)
        let dropped = try store.apply([.init(op: "drop", args: JSONObject([(key: "id", value: monthly)]), actor: user)], now: now)
        let unchecked = TekaStore(folder: folder)
        let before = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        let rule = JSONValue.obj([("freq", .str("monthly")), ("day", .int(10))])
        #expect(throws: TekaStore.Refused.self) {
            try unchecked.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: .str("estate-example-2026-007")),
                                                                            (key: "set", value: .obj([("recurrence", rule)]))]), actor: user)], now: now)
        }
        // Undo would bring the dropped series back, which is a new repeat too.
        #expect(throws: TekaStore.Refused.self) { try unchecked.undo(opID: dropped[0]["id"]!.stringValue!, now: now) }
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == before)
        // Closing a to-do and removing a repeat stay open to it: neither adds a series lifeproj could end.
        _ = try done(unchecked, .str("estate-example-2026-007"), shown: nil, now: now)
        #expect(TekaStore.writesRepeat(.init(op: "update_item", args: JSONObject([(key: "id", value: monthly),
                                                                                 (key: "unset", value: .array([.str("recurrence")]))]), actor: user)) == false)
    }

    // MARK: The guard

    func line(_ type: String, _ args: [(String, JSONValue)], kind: String = "user", at: String = "2026-11-10T12:00:00Z") -> JSONObject {
        let actor = JSONObject([(key: "kind", value: .string(kind)), (key: "client", value: .str("sprava/0.1"))])
        var op = JSONObject([(key: "id", value: .str(UUID().uuidString.lowercased())), (key: "at", value: .string(at)),
                             (key: "actor", value: .object(actor))])
        if kind == "brain" {
            op.set("proposal", .str("p1"))
            op.set("approved_by", .str("user"))
        }
        op.set("op", .string(type))
        op.set("args", .obj(args))
        return op
    }

    func catalog() throws -> JSONObject {
        let url = try #require(TestFixtures.bundle.url(forResource: "sprava-v0", withExtension: "json", subdirectory: "Fixtures"))
        return try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
    }

    func refused(_ op: JSONObject, _ word: String) throws {
        let c = try catalog()
        #expect { try TransactionGuard.check([op], on: c) } throws: { ($0 as? TransactionGuard.Rejection)?.description.contains(word) == true }
    }

    @Test func thePersonSetsAndRemovesARepeat() throws {
        let c = try catalog()
        let id = JSONValue.str("estate-example-2026-007")
        let yearly = JSONValue.obj([("freq", .str("yearly")), ("month", .int(10)), ("day", .int(10))])
        let (set, _) = try TransactionGuard.check([line("update_item", [("id", id), ("set", .obj([("recurrence", yearly)]))])], on: c)
        #expect(set["open_items"]?.arrayValue?.first { $0["id"] == id }?["recurrence"] == yearly)
        let (unset, _) = try TransactionGuard.check([line("update_item", [("id", monthly), ("unset", .array([.str("recurrence")]))])], on: c)
        #expect(unset["open_items"]?.arrayValue?.first { $0["id"] == monthly }?["recurrence"] == nil)
        // A new to-do may repeat from the start.
        let new = JSONValue.obj([("id", .str("estate-example-2026-020")), ("title", .str("Invented monthly reading")), ("status", .str("open")),
                                 ("priority", .str("normal")), ("due", .str("2026-12-01")), ("recurrence", .obj([("freq", .str("monthly")), ("day", .int(1))]))])
        _ = try TransactionGuard.check([line("add_item", [("item", new)])], on: c)
    }

    @Test func noOneButThePersonSetsARepeat() throws {
        let rule = JSONValue.obj([("freq", .str("monthly")), ("day", .int(10))])
        for kind in ["brain", "external"] {
            try refused(line("update_item", [("id", .str("estate-example-2026-007")), ("set", .obj([("recurrence", rule)]))], kind: kind), "repeat")
            try refused(line("update_item", [("id", monthly), ("unset", .array([.str("recurrence")]))], kind: kind), "repeat")
        }
        // Dismissal stays with the hub, for the person too.
        try refused(line("update_item", [("id", .str("estate-example-2026-007")), ("set", .obj([("dismissed", .bool(true))]))]), "dismissed")
    }

    @Test func aMalformedRepeatOrOneWithoutADateIsRefused() throws {
        let id = JSONValue.str("estate-example-2026-007")
        for rule: JSONValue in [.obj([("freq", .str("monthly")), ("day", .int(32))]), .obj([("freq", .str("yearly")), ("day", .int(5))]),
                                .obj([("freq", .str("yearly")), ("month", .int(13)), ("day", .int(5))]), .obj([("freq", .str("daily")), ("day", .int(5))])] {
            try refused(line("update_item", [("id", id), ("set", .obj([("recurrence", rule)]))]), "repeat")
        }
        // A repeating item keeps a due date: it cannot become dateless.
        try refused(line("update_item", [("id", monthly), ("set", .obj([("no_deadline", .bool(true))])), ("unset", .array([.str("due")]))]), "due")
    }

    @Test func aCompletionMustNameTheCurrentOccurrenceAndItsRealNextDate() throws {
        let c = try catalog()
        func complete(_ shown: String?, _ next: String?) -> JSONObject {
            var args: [(String, JSONValue)] = [("id", monthly), ("source", .str("user"))]
            if let shown { args.append(("occurrence_due", .string(shown))) }
            if let next { args.append(("next_due", .string(next))) }
            return line("complete", args)
        }
        _ = try TransactionGuard.check([complete("2026-11-14", "2026-12-14")], on: c)
        try refused(complete("2026-10-14", "2026-12-14"), "moved on")          // an occurrence already done
        try refused(complete("2026-11-14", "2027-01-14"), "next date")         // skips an occurrence
        try refused(complete("2026-11-14", "2026-11-20"), "next date")         // not on the rule's day
        try refused(complete(nil, "2026-12-14"), "go together")
        // A one-off never takes occurrence_due alone.
        try refused(line("complete", [("id", .str("estate-example-2026-007")), ("occurrence_due", .str("2026-10-10"))]), "go together")
    }
}
