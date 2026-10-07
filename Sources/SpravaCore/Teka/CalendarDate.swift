import Foundation

/// A day on the proleptic Gregorian calendar, with no time zone. Arithmetic is on day numbers, never on
/// seconds (teka-v0 §5.2).
public struct CalendarDate: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Returns nil unless the date exists.
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...CalendarDate.daysIn(month: month, year: year)).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }

    public static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days since 0001-01-01 (day 0), using the civil-from-days algorithm.
    public var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468 + 719_162   // shift epoch from 1970-01-01 to 0001-01-01
    }

    public init(dayNumber: Int) {
        let z = dayNumber - 719_162 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        self.year = y
        self.month = m
        self.day = d
    }

    public func adding(days: Int) -> CalendarDate { CalendarDate(dayNumber: dayNumber + days) }

    /// Calendar days from `self` to `other`; negative when `other` is earlier.
    public func days(to other: CalendarDate) -> Int { other.dayNumber - dayNumber }

    /// ISO weekday, Monday = 1 ... Sunday = 7.
    public var isoWeekday: Int {
        // 0001-01-01 was a Monday.
        ((dayNumber % 7) + 7) % 7 + 1
    }

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool { lhs.dayNumber < rhs.dayNumber }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The date of `date` in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self = CalendarDate(year: parts.year!, month: parts.month!, day: parts.day!)!
    }

    // MARK: - Parsing

    /// `YYYY-MM-DD` only, naming a real date: the only form a v0 writer writes (teka-v0 §4.4).
    public static func strict(_ text: String) -> CalendarDate? {
        let b = Array(text.utf8)
        guard b.count == 10, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              let y = digits(b, 0, 4), let m = digits(b, 5, 2), let d = digits(b, 8, 2) else { return nil }
        return CalendarDate(year: y, month: m, day: d)
    }

    /// Every form Python 3.11's `date.fromisoformat` accepts, which is what lifeproj buckets with
    /// (teka-v0 §5.2): `YYYY-MM-DD`, `YYYYMMDD`, `YYYY-Www`, `YYYYWww`, `YYYY-Www-D`, `YYYYWwwD`.
    public static func lenient(_ text: String) -> CalendarDate? {
        if let date = strict(text) { return date }
        let b = Array(text.utf8)
        if b.count == 8, let y = digits(b, 0, 4), let m = digits(b, 4, 2), let d = digits(b, 6, 2) {
            return CalendarDate(year: y, month: m, day: d)
        }
        // Week dates.
        guard b.count >= 7, let y = digits(b, 0, 4) else { return nil }
        var i = 4
        let dashed = b[i] == UInt8(ascii: "-")
        if dashed { i += 1 }
        guard i < b.count, b[i] == UInt8(ascii: "W"), let w = digits(b, i + 1, 2) else { return nil }
        i += 3
        var weekday = 1
        if i < b.count {
            if dashed {
                guard b[i] == UInt8(ascii: "-") else { return nil }
                i += 1
            }
            guard i == b.count - 1, let d = digits(b, i, 1), (1...7).contains(d) else { return nil }
            weekday = d
        } else if i != b.count {
            return nil
        }
        return isoWeekDate(year: y, week: w, weekday: weekday)
    }

    static func isoWeekDate(year: Int, week: Int, weekday: Int) -> CalendarDate? {
        guard week >= 1, let jan4 = CalendarDate(year: year, month: 1, day: 4) else { return nil }
        let week1Monday = jan4.adding(days: 1 - jan4.isoWeekday)
        // Number of ISO weeks in the year: 53 when Dec 28 falls in week 53.
        let dec28 = CalendarDate(year: year, month: 12, day: 28)!
        let lastWeek = (dec28.dayNumber - week1Monday.dayNumber) / 7 + 1
        guard week <= lastWeek else { return nil }
        return week1Monday.adding(days: (week - 1) * 7 + weekday - 1)
    }

    private static func digits(_ b: [UInt8], _ start: Int, _ count: Int) -> Int? {
        guard start >= 0, start + count <= b.count else { return nil }
        var value = 0
        for i in start..<(start + count) {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b[i]) else { return nil }
            value = value * 10 + Int(b[i] - UInt8(ascii: "0"))
        }
        return value
    }
}

/// RFC 3339 date-times, as found in `closed_at` and `at` (teka-v0 §5.2).
public enum Timestamp {
    public static func parse(_ text: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        let normalized = text.replacingOccurrences(of: "z", with: "Z")
        return (try? withFraction.parse(normalized)) ?? (try? plain.parse(normalized))
    }
}
