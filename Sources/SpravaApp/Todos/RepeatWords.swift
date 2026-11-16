import BinderFormat
import BinderStore
import SpravaKit

/// How a to-do's repeat reads in the app: the row's short line, the editor's choices and the line after a Done.
enum RepeatWords {
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                         "November", "December"]

    /// 1st, 2nd, 3rd, 4th, 11th, 12th, 13th, 21st, 22nd, 23rd, 31st.
    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// The row's line: "repeats monthly on the 15th", "repeats yearly on July 30".
    static func line(_ rule: Recurrence.Rule) -> String {
        switch rule {
        case .monthly(let day): "repeats monthly on the \(ordinal(day))"
        case .yearly(let month, let day): "repeats yearly on \(months[month - 1]) \(day)"
        }
    }

    /// The row's line for an item; nil when it does not repeat, and a plain "repeats" for a rule this version cannot read.
    static func line(_ item: Item) -> String? {
        guard item.hasRecurrence else { return nil }
        return Recurrence.rule(item.object?["recurrence"]).map(line) ?? "repeats"
    }

    /// "December 15", with the year only when it is not this year's: the date a Done moved a repeating to-do to.
    static func spoken(_ day: CalendarDate, today: CalendarDate) -> String {
        "\(months[day.month - 1]) \(day.day)" + (day.year == today.year ? "" : ", \(day.year)")
    }

    /// What follows a Done on a repeating to-do: "Next: December 15."
    static func next(_ day: CalendarDate, today: CalendarDate) -> String { "Next: \(spoken(day, today: today))." }

    /// The Repeats choice the editor starts a series with, from the date the to-do is due: monthly on that day, or
    /// yearly on that month and day.
    static func monthly(from due: CalendarDate) -> Recurrence.Rule { .monthly(day: due.day) }
    static func yearly(from due: CalendarDate) -> Recurrence.Rule { .yearly(month: due.month, day: due.day) }

    /// The editor's name for a rule: "Monthly on the 15th", "Yearly on July 30".
    static func choice(_ rule: Recurrence.Rule) -> String {
        let text = line(rule).dropFirst("repeats ".count)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// What Done says on a repeat by a rule this version cannot read, which has no next date here.
    static let unreadableDone = "This to-do repeats by a rule this version of Sprava cannot read, so it cannot be marked done here."
}

extension Item {
    /// The item's repeat as binder-v0 §5.4 writes it; nil when it has none or one this version cannot read.
    var repeatRule: Recurrence.Rule? { Recurrence.rule(object?["recurrence"]) }
    /// Whether it repeats by a rule this version cannot read: no Done moves it on, so none is sent.
    var repeatUnreadable: Bool { hasRecurrence && repeatRule == nil }
    /// The date a Done on this item completes, which the store checks is still its due date (binder-v0 §5.4); nil for an
    /// item that does not repeat.
    var occurrence: CalendarDate? { repeatRule == nil ? nil : due }

    /// The `complete` or `drop` args the person's Done or Cancel sends; a Done on a repeating item names its occurrence.
    func closeArgs(_ op: String, at: String) -> JSONValue? {
        guard let id = object?["id"] else { return nil }
        var args = JSONObject([(key: "id", value: id), (key: "closed_at", value: .string(at)), (key: "source", value: .str("user"))])
        if op == "complete", let occurrence { args.set("occurrence_due", .string(occurrence.description)) }
        return .object(args)
    }
}
