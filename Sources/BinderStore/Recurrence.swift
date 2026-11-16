import Foundation
import SpravaKit

/// The recurrence rule of binder-v0 §5.4: `{"freq": "monthly", "day": D}` or `{"freq": "yearly", "month": M, "day": D}`,
/// and the one date arithmetic every writer of a recurring completion uses.
public enum Recurrence {
    public enum Rule: Equatable, Sendable {
        case monthly(day: Int)
        case yearly(month: Int, day: Int)

        /// The rule as the catalog stores it. `month` is written only for a yearly rule.
        public var json: JSONValue {
            switch self {
            case .monthly(let day): .obj([("freq", .str("monthly")), ("day", .int(day))])
            case .yearly(let month, let day): .obj([("freq", .str("yearly")), ("month", .int(month)), ("day", .int(day))])
            }
        }
    }

    /// The rule `value` holds, nil when it is absent or breaks §5.4's shape (the shape item.schema.json checks):
    /// `freq` monthly or yearly, an integer `day` in 1...31, and an integer `month` in 1...12 for a yearly rule.
    /// `month` is ignored on a monthly rule, but one out of range still makes the rule malformed, as the schema says.
    public static func rule(_ value: JSONValue?) -> Rule? {
        guard case .object(let r)? = value else { return nil }
        func integer(_ key: String, in range: ClosedRange<Int>) -> Int?? {
            guard let v = r[key] else { return .some(nil) }
            guard let n = v.numberValue else { return nil }
            let whole = n.safeInteger ?? n.doubleValue.flatMap { $0.rounded() == $0 && abs($0) <= 1e15 ? Int64($0) : nil }
            guard let whole, let i = Int(exactly: whole), range.contains(i) else { return nil }
            return .some(i)
        }
        guard let dayField = integer("day", in: 1...31), let day = dayField, let monthField = integer("month", in: 1...12) else { return nil }
        switch r["freq"]?.stringValue {
        case "monthly": return .monthly(day: day)
        case "yearly": return monthField.map { .yearly(month: $0, day: day) }
        default: return nil
        }
    }

    /// `next_after(d)`: the first date strictly after `d` that matches the rule, with month-length clamping: in a month
    /// shorter than the rule's day the occurrence falls on that month's last day (binder-v0 §5.4). Nil past 9999.
    public static func nextAfter(_ d: CalendarDate, _ rule: Rule) -> CalendarDate? {
        func clamped(year: Int, month: Int, day: Int) -> CalendarDate? {
            CalendarDate(year: year, month: month, day: min(day, CalendarDate.daysIn(month: month, year: year)))
        }
        switch rule {
        case .monthly(let day):
            // This month's occurrence when it is still ahead, else next month's.
            if let here = clamped(year: d.year, month: d.month, day: day), here > d { return here }
            let (year, month) = d.month == 12 ? (d.year + 1, 1) : (d.year, d.month + 1)
            return clamped(year: year, month: month, day: day)
        case .yearly(let month, let day):
            if let here = clamped(year: d.year, month: month, day: day), here > d { return here }
            return clamped(year: d.year + 1, month: month, day: day)
        }
    }

    /// The `next_due` of completing the occurrence due on `occurrence` on day `today`: `next_after(max(due, today))`,
    /// strictly later than both, so the next date never lands in the past (binder-v0 §5.4).
    public static func nextDue(occurrence: CalendarDate, today: CalendarDate, _ rule: Rule) -> CalendarDate? {
        nextAfter(max(occurrence, today), rule)
    }

    /// The day an op is applied on: the local date of its `at`. The writer and the guard both read it from the op's own
    /// `at`, so an op recorded before it is applied (a phone's decision) is judged on the day it was made.
    public static func day(ofAt at: String, in timeZone: TimeZone = .current) -> CalendarDate? {
        Timestamp.parse(at).flatMap { CalendarDate($0, in: timeZone) }
    }

    /// Fills `next_due` for a `complete` of a recurring item that names the occurrence it completes (binder-v0 §5.4):
    /// the args are left as they are for any other item. `occurrence_due` is the due date the person saw; when the item
    /// has moved on since (another window, the phone or an earlier Done), the completion is refused, so one Done never
    /// advances a series twice or skips an occurrence.
    public static func fillNextDue(_ args: inout JSONObject, item: JSONObject?, at: String) throws {
        guard args["next_due"] == nil, let item, let rule = rule(item["recurrence"]) else { return }
        guard let shown = args["occurrence_due"]?.stringValue.flatMap(CalendarDate.strict) else {
            throw TekaStore.Refused(reason: "this to-do repeats, and the change does not say which date was done; nothing was changed")
        }
        guard item["due"] == .string(shown.description) else {
            throw TekaStore.Refused(reason: "this to-do already moved on to its next date; nothing was changed")
        }
        guard let today = day(ofAt: at), let next = nextDue(occurrence: shown, today: today, rule) else {
            throw TekaStore.Refused(reason: "the next date of this repeating to-do cannot be worked out; nothing was changed")
        }
        args.set("next_due", .string(next.description))
    }
}
