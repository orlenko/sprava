import Foundation
import SpravaKit

/// A due date as a person types and reads it. English only, like the rest of the app.
enum TodoDates {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// `today`, `tomorrow`, a weekday, `+3`, `nov 12`, `12 nov`, `11/12` (month first), or a full date; nil when it is none
    /// of these or names a day that does not exist. A date with no year is its next occurrence.
    static func parse(_ text: String, today: CalendarDate) -> CalendarDate? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch typed {
        case "today": return today
        case "tomorrow", "tom": return today.checkedAdding(days: 1)
        case "yesterday": return today.checkedAdding(days: -1)
        default: break
        }
        if typed.hasPrefix("+"), let days = Int(typed.dropFirst()), (0...3650).contains(days) { return today.checkedAdding(days: days) }
        if let weekday = weekdays.firstIndex(where: { typed == $0 || (typed.count > 3 && fullWeekday($0).hasPrefix(typed)) }) {
            return today.checkedAdding(days: (weekday - weekdayIndex(today) + 7) % 7 == 0 ? 7 : (weekday - weekdayIndex(today) + 7) % 7)
        }
        if let full = CalendarDate.strict(typed) { return full }
        let parts = typed.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        if parts.count == 2 || parts.count == 3 {
            let year = parts.count == 3 ? Int(parts[2]) : nil
            guard parts.count == 2 || year != nil else { return nil }
            if let month = month(parts[0]), let day = Int(parts[1]) { return occurrence(month, day, year, today) }
            if let day = Int(parts[0]), let month = month(parts[1]) { return occurrence(month, day, year, today) }
            return nil
        }
        let slashed = typed.split(separator: "/", omittingEmptySubsequences: false).compactMap { Int($0) }
        if slashed.count == 2 || slashed.count == 3, slashed.count == typed.split(separator: "/", omittingEmptySubsequences: false).count {
            return occurrence(slashed[0], slashed[1], slashed.count == 3 ? slashed[2] : nil, today)
        }
        return nil
    }

    private static func fullWeekday(_ short: String) -> String {
        ["sun": "sunday", "mon": "monday", "tue": "tuesday", "wed": "wednesday", "thu": "thursday", "fri": "friday", "sat": "saturday"][short] ?? short
    }

    private static func month(_ word: String) -> Int? {
        guard word.count >= 3, let index = months.firstIndex(where: { word.hasPrefix($0) }) else { return nil }
        return index + 1
    }

    private static func occurrence(_ month: Int, _ day: Int, _ year: Int?, _ today: CalendarDate) -> CalendarDate? {
        if let year { return CalendarDate(year: year < 100 ? 2000 + year : year, month: month, day: day) }
        if let this = CalendarDate(year: today.year, month: month, day: day), this >= today { return this }
        return CalendarDate(year: today.year + 1, month: month, day: day)
    }

    /// 0 for Sunday. 2001-01-07 was a Sunday.
    private static func weekdayIndex(_ day: CalendarDate) -> Int {
        let reference = CalendarDate(year: 2001, month: 1, day: 7)!
        return ((reference.days(to: day) % 7) + 7) % 7
    }

    /// `Today`, `Tomorrow`, `Nov 6`, or `Nov 6, 2031` outside this year.
    static func label(_ day: CalendarDate, today: CalendarDate) -> String {
        if day == today { return "Today" }
        if day == today.checkedAdding(days: 1) { return "Tomorrow" }
        let short = months[day.month - 1].capitalized + " \(day.day)"
        return day.year == today.year ? short : short + ", \(day.year)"
    }
}

extension CalendarDate {
    /// The day as the Today page's title says it: "Tuesday, November 3".
    var spoken: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return description }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}
