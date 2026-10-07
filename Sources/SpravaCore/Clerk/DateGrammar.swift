import Foundation

/// Code resolves time words; the model never writes a date (capture-event-v0 §6.6). English and French rules,
/// predictable on purpose: anything else stays as text for the person to type.
public enum DateGrammar {
    public enum Role: String, Sendable { case due, expected, follow_up }

    public struct Found: Equatable, Sendable {
        public var text: String
        public var date: CalendarDate?
    }

    static let weekdaysEN = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let weekdaysFR = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
    static let monthsEN = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let monthsFR = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
    static let ordinalsEN: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17,
        "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "twenty-first": 21, "twenty-second": 22, "twenty-third": 23,
        "twenty-fourth": 24, "twenty-fifth": 25, "twenty-sixth": 26, "twenty-seventh": 27, "twenty-eighth": 28,
        "twenty-ninth": 29, "thirtieth": 30, "thirty-first": 31,
    ]
    static let smallNumbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "a": 1, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six ": 6, "sept": 7, "huit": 8, "neuf": 9, "dix": 10,
        "quinze": 15,
    ]

    static func weekday(_ d: CalendarDate) -> Int {   // 0 = Sunday
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let date = c.date(from: DateComponents(year: d.year, month: d.month, day: d.day))!
        return c.component(.weekday, from: date) - 1
    }

    static func daysIn(_ year: Int, _ month: Int) -> Int {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let date = c.date(from: DateComponents(year: year, month: month, day: 1))!
        return c.range(of: .day, in: .month, for: date)!.count
    }

    static func isFrench(_ locale: String) -> Bool { locale.lowercased().hasPrefix("fr") }

    /// Resolves one time expression. `nil` date means "a time expression, left unresolved".
    /// Returns `nil` when the text is not a time expression at all.
    public static func resolve(_ raw: String, anchor today: CalendarDate, locale: String) -> Found? {
        let text = raw.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !text.isEmpty else { return nil }
        var words = text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        // Strip prefixes and hedges.
        let hadArticle = ["the", "le"].contains(words.dropFirst(words.first.map { ["by", "before", "on", "until", "d'ici", "avant"].contains($0) } == true ? 1 : 0).first ?? "")
        let prefixes: Set<String> = ["by", "before", "on", "at", "the", "latest", "until", "around", "probably", "maybe",
                                     "d'ici", "avant", "au", "plus", "tard", "jusqu'à", "sans", "doute", "le", "la", "à", "this", "ce", "cette", "of"]
        while let w = words.first, prefixes.contains(w) { words.removeFirst() }
        while let w = words.last, ["latest", "tard"].contains(w) { words.removeLast() }
        let t = words.joined(separator: " ")
        let fr = isFrench(locale)
        let wasThis = text.contains("this ") || text.hasPrefix("ce ")

        // ISO date.
        if let d = CalendarDate.strict(t) { return Found(text: raw, date: d) }
        if t.wholeMatch(of: /\d{1,4}[\/.\-]\d{1,2}([\/.\-]\d{2,4})?/) != nil {
            // Day-first for fr-FR only; every other numeric form stays unresolved.
            if locale.lowercased() == "fr-fr", let m = t.wholeMatch(of: /(\d{1,2})[\/.](\d{1,2})[\/.](\d{4})/),
               let d = CalendarDate(year: Int(m.output.3)!, month: Int(m.output.2)!, day: Int(m.output.1)!) {
                return Found(text: raw, date: d)
            }
            return Found(text: raw, date: nil)
        }
        switch t {
        case "today", "tonight", "aujourd'hui", "ce soir": return Found(text: raw, date: today)
        case "tomorrow", "demain": return Found(text: raw, date: today.adding(days: 1))
        case "day after tomorrow", "après-demain": return Found(text: raw, date: today.adding(days: 2))
        case "next week", "semaine prochaine":
            let wd = weekday(today)
            let toMonday = (8 - wd) % 7 == 0 ? 7 : (8 - wd) % 7
            return Found(text: raw, date: today.adding(days: toMonday))
        case "end of the month", "end of month", "fin du mois", "fin de mois":
            return Found(text: raw, date: CalendarDate(year: today.year, month: today.month, day: daysIn(today.year, today.month)))
        case "end of the year", "end of year", "fin de l'année", "fin d'année":
            return Found(text: raw, date: CalendarDate(year: today.year, month: 12, day: 31))
        case "end of the week", "fin de la semaine", "next month", "le mois prochain", "mois prochain", "soon", "bientôt", "later", "plus tard":
            return Found(text: raw, date: nil)
        case "yesterday", "hier", "last week", "la semaine dernière":
            return Found(text: raw, date: nil)   // before the capture: never a due date
        default: break
        }
        // "in three days", "dans deux semaines"
        if let m = t.wholeMatch(of: /(?:in|within|dans) (\w+) (days?|weeks?|jours?|semaines?)/) {
            let n = Int(m.output.1) ?? smallNumbers[String(m.output.1)]
            guard let n else { return Found(text: raw, date: nil) }
            let unit = String(m.output.2)
            return Found(text: raw, date: today.adding(days: unit.hasPrefix("w") || unit.hasPrefix("s") ? n * 7 : n))
        }
        // Weekdays: "friday", "next thursday" (unresolved), "jeudi prochain" (unresolved).
        let weekdays = fr ? weekdaysFR : weekdaysEN
        if let i = weekdays.firstIndex(of: t) ?? weekdaysEN.firstIndex(of: t) ?? weekdaysFR.firstIndex(of: t) {
            let wd = weekday(today)
            var delta = (i - wd + 7) % 7
            if delta == 0 { delta = wasThis ? 0 : 7 }
            return Found(text: raw, date: today.adding(days: delta))
        }
        if let m = t.wholeMatch(of: /next (\w+)|(\w+) prochain/) {
            let w = String(m.output.1 ?? m.output.2 ?? "")
            if weekdaysEN.contains(w) || weekdaysFR.contains(w) { return Found(text: raw, date: nil) }
        }
        // Day of the month: "the 15th", "15th", "the fifteenth", "le 15", "le quinze".
        if let day = dayOfMonth(t, article: hadArticle) {
            return Found(text: raw, date: nextDayOfMonth(day, after: today))
        }
        // Month and day: "october 3", "3 october", "le 3 octobre", "october 3rd".
        if let (month, day, year) = monthDay(t) {
            if let year { return Found(text: raw, date: CalendarDate(year: year, month: month, day: day)) }
            guard let candidate = CalendarDate(year: today.year, month: month, day: day) else { return Found(text: raw, date: nil) }
            if candidate >= today { return Found(text: raw, date: candidate) }
            let ago = candidate.days(to: today)
            if ago < 60 { return Found(text: raw, date: nil) }   // most likely the past date
            return Found(text: raw, date: CalendarDate(year: today.year + 1, month: month, day: day))
        }
        return nil
    }

    /// A day of the month: "15th", "fifteenth", or a bare number only after an article ("the 15", "le 15", "le quinze").
    static func dayOfMonth(_ t: String, article: Bool) -> Int? {
        if let m = t.wholeMatch(of: /(\d{1,2})(st|nd|rd|th|er)?/), let d = Int(m.output.1), (1...31).contains(d),
           article || m.output.2 != nil { return d }
        if let d = ordinalsEN[t] { return d }
        if article, let d = smallNumbers[t], t != "a", t != "un", t != "une" { return d }
        return nil
    }

    static func nextDayOfMonth(_ day: Int, after today: CalendarDate) -> CalendarDate? {
        if day > today.day, day <= daysIn(today.year, today.month) { return CalendarDate(year: today.year, month: today.month, day: day) }
        if day > today.day { return nil }   // the month does not have that day
        let (y, mo) = today.month == 12 ? (today.year + 1, 1) : (today.year, today.month + 1)
        return day <= daysIn(y, mo) ? CalendarDate(year: y, month: mo, day: day) : nil
    }

    static func monthDay(_ t: String) -> (Int, Int, Int?)? {
        let words = t.split(separator: " ").map(String.init)
        guard words.count >= 2, words.count <= 3 else { return nil }
        func month(_ w: String) -> Int? { (monthsEN.firstIndex(of: w) ?? monthsFR.firstIndex(of: w)).map { $0 + 1 } }
        var m: Int?, d: Int?, y: Int?
        for w in words {
            if let mo = month(w) { m = mo } else if let n = dayOfMonth(w, article: true), d == nil { d = n }
            else if let n = Int(w), n >= 1000 { y = n } else { return nil }
        }
        guard let m, let d else { return nil }
        return (m, d, y)
    }

    /// The role from the words before the time expression in its sentence (capture-event-v0 §6.6).
    public static func role(sentence: String, whenText: String, waiting: Bool) -> Role {
        let s = sentence.lowercased().replacingOccurrences(of: "’", with: "'")
        guard let r = s.range(of: whenText.lowercased()) else { return waiting ? .expected : .due }
        let before = s[..<r.lowerBound].split(whereSeparator: { $0 == " " || $0 == "," }).suffix(6).map(String.init)
        func inOrder(_ pattern: [String]) -> Bool {
            var i = 0
            for w in before where i < pattern.count && w == pattern[i] { i += 1 }
            return i == pattern.count
        }
        let lowerWhen = whenText.lowercased()
        if inOrder(["if", "not", "by"]) || inOrder(["if", "nothing", "by"]) || s.contains("follow up") || s.contains("relancer") { return .follow_up }
        if ["until", "within", "jusqu'à"].contains(where: { before.contains($0) || lowerWhen.hasPrefix($0) }) || inOrder(["should", "arrive"]) { return .expected }
        if ["by", "before", "d'ici", "avant"].contains(where: { before.contains($0) || lowerWhen.hasPrefix($0 + " ") }) { return .due }
        return waiting ? .expected : .due
    }

    /// Time expressions code can find in a sentence by itself, for the "date taken from the sentence" check.
    public static func scan(_ sentence: String, anchor today: CalendarDate, locale: String) -> Found? {
        let words = sentence.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        // Longest match first, up to four words.
        for length in stride(from: 4, through: 1, by: -1) where words.count >= length {
            for i in 0...(words.count - length) {
                let phrase = words[i..<(i + length)].joined(separator: " ")
                if let f = resolve(phrase, anchor: today, locale: locale), isMeaningful(phrase) { return Found(text: phrase, date: f.date) }
            }
        }
        return nil
    }

    /// Single small words such as "a" or "one" are numbers, not dates, when they stand alone.
    static func isMeaningful(_ phrase: String) -> Bool {
        let p = phrase.lowercased()
        if smallNumbers[p] != nil || p.wholeMatch(of: /\d{1,2}/) != nil { return false }
        return true
    }
}
