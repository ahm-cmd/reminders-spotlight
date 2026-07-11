import EventKit

class CalendarParser {
    struct TextCalendarResult {
        private let range: NSRange
        let string: String
        let calendar: EKCalendar?
        
        var highlightedText: RmbHighlightedTextField.HighlightedText {
            RmbHighlightedTextField.HighlightedText(range: range, color: calendar?.color ?? .white)
        }
        
        init() {
            self.range = NSRange()
            self.string = ""
            self.calendar = nil
        }
        
        init(range: NSRange, string: String, calendar: EKCalendar?) {
            self.range = range
            self.string = string
            self.calendar = calendar
        }
    }
    
    private var calendarsByTitle: [String: EKCalendar] = [:]
    private var simplifiedCalendarTitles: [String] = []
    /// User-defined `@` shortcut keys (lowercased, no `@`) → calendar.
    private var shortcutCalendarsByKey: [String: EKCalendar] = [:]
    
    static private let validInitialChars: Set<String?> = ["/", "@"]
    
    static let shared = CalendarParser()
    
    private init() {
        // This prevents others from using the default '()' initializer for this class.
    }
    
    static func updateShared(with calendars: [EKCalendar]) {
        CalendarParser.shared.calendarsByTitle = calendars
            .reduce(into: [String: EKCalendar](), { partialResult, calendar in
                let simplifiedTitle = calendar.title.lowercased().replacingOccurrences(of: " ", with: "-")
                partialResult[simplifiedTitle] = calendar
            })
        CalendarParser.shared.simplifiedCalendarTitles = Array(CalendarParser.shared.calendarsByTitle.keys)

        // Resolve the user's @ shortcuts (key → calendar identifier) to calendars.
        let calendarsById = Dictionary(
            calendars.map { ($0.calendarIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        CalendarParser.shared.shortcutCalendarsByKey = UserPreferences.shared.listShortcuts
            .reduce(into: [String: EKCalendar]()) { result, pair in
                if let calendar = calendarsById[pair.value] {
                    result[pair.key.lowercased()] = calendar
                }
            }
    }
    
    static func isInitialCharValid(_ char: String?) -> Bool {
        return validInitialChars.contains(char)
    }
    
    static func getCalendar(from textString: String) -> TextCalendarResult? {
        let byTitle = CalendarParser.shared.calendarsByTitle
        let byShortcut = CalendarParser.shared.shortcutCalendarsByKey
        let words = textString.split(separator: " ")

        // 0. User-defined "@" shortcut: e.g. "@p" → the chosen list. Checked
        //    before the title forms so a shortcut always wins over a same-named
        //    list, and so "@p" is the token stripped from the title.
        if !byShortcut.isEmpty,
           let match = words.first(where: {
               $0.hasPrefix("@") && byShortcut[$0.dropFirst().lowercased()] != nil
           }) {
            let range = NSRange(match.startIndex..<match.endIndex, in: textString)
            return TextCalendarResult(range: range, string: String(match), calendar: byShortcut[match.dropFirst().lowercased()])
        }

        // 1. Explicit prefix form: "/List" or "@List".
        let prefixed = words.filter { CalendarParser.isInitialCharValid(String($0.prefix(1))) }
        if let match = prefixed.first(where: { byTitle[$0.dropFirst().lowercased()] != nil }) {
            let range = NSRange(match.startIndex..<match.endIndex, in: textString)
            return TextCalendarResult(range: range, string: String(match), calendar: byTitle[match.dropFirst().lowercased()])
        }

        // 2. Bare form: a standalone word that exactly matches a (single-word)
        //    list name — e.g. typing "Work" assigns to the Work list.
        if let match = words.first(where: { byTitle[$0.lowercased()] != nil }) {
            let range = NSRange(match.startIndex..<match.endIndex, in: textString)
            return TextCalendarResult(range: range, string: String(match), calendar: byTitle[match.lowercased()])
        }

        return nil
    }
    
    static func autoCompleteSuggestions(_ typingWord: String) -> [String] {
        let lowercasedTypingWord = typingWord.lowercased()
        let maxSuggestions = 3
        let matches = CalendarParser.shared.simplifiedCalendarTitles
            .filter({ $0.count > lowercasedTypingWord.count && $0.hasPrefix(lowercasedTypingWord) })
            .sorted(by: { $0.count < $1.count })
            .prefix(maxSuggestions)
        return matches.map({ typingWord + $0.dropFirst(typingWord.count) })
    }
}

/// Resolves `@key` calendar shortcuts for new calendar EVENTS — the event-mode
/// analog of CalendarParser's `@` list shortcuts. Keeps a separate map so a key
/// can mean different things in reminder mode vs event mode.
class EventCalendarParser {
    struct Match {
        let range: NSRange
        let string: String
        let calendar: EKCalendar
    }

    static let shared = EventCalendarParser()
    private var shortcutCalendarsByKey: [String: EKCalendar] = [:]

    private init() {}

    static func updateShared(with calendars: [EKCalendar]) {
        let calendarsById = Dictionary(
            calendars.map { ($0.calendarIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        EventCalendarParser.shared.shortcutCalendarsByKey = UserPreferences.shared.eventCalendarShortcuts
            .reduce(into: [String: EKCalendar]()) { result, pair in
                if let calendar = calendarsById[pair.value] {
                    result[pair.key.lowercased()] = calendar
                }
            }
    }

    static func match(in textString: String) -> Match? {
        let byShortcut = EventCalendarParser.shared.shortcutCalendarsByKey
        guard !byShortcut.isEmpty else { return nil }
        let words = textString.split(separator: " ")
        guard let word = words.first(where: {
            $0.hasPrefix("@") && byShortcut[$0.dropFirst().lowercased()] != nil
        }), let calendar = byShortcut[word.dropFirst().lowercased()] else {
            return nil
        }
        let range = NSRange(word.startIndex..<word.endIndex, in: textString)
        return Match(range: range, string: String(word), calendar: calendar)
    }
}

/// Parses common "every …" recurrence phrases into an EKRecurrenceRule for new
/// calendar events. Best-effort — covers daily/weekly/monthly/yearly, weekdays,
/// and a specific weekday ("every Monday").
class RecurrenceParser {
    struct Match {
        // Base recurrence + an optional end clause are separate tokens, so keep
        // each range/substring for highlighting and stripping.
        let ranges: [NSRange]
        let strings: [String]
        let rule: EKRecurrenceRule
        let label: String

        var range: NSRange { ranges.first ?? NSRange() }
        var string: String { strings.first ?? "" }
    }

    private struct Base {
        let frequency: EKRecurrenceFrequency
        let days: [EKWeekday]?
        var interval: Int = 1
        let label: String
        let range: NSRange
        let string: String
    }

    private struct End {
        let recurrenceEnd: EKRecurrenceEnd
        let label: String
        let range: NSRange
        let string: String
    }

    private static let weekdays: [(names: String, day: EKWeekday, label: String)] = [
        ("mondays?|mon", .monday, "Mon"),
        ("tuesdays?|tue", .tuesday, "Tue"),
        ("wednesdays?|wed", .wednesday, "Wed"),
        ("thursdays?|thu", .thursday, "Thu"),
        ("fridays?|fri", .friday, "Fri"),
        ("saturdays?|sat", .saturday, "Sat"),
        ("sundays?|sun", .sunday, "Sun")
    ]

    static func match(in text: String) -> Match? {
        guard let base = baseRecurrence(in: text) else { return nil }
        let end = endClause(in: text)
        let rule = makeRule(frequency: base.frequency, days: base.days, interval: base.interval, end: end?.recurrenceEnd)

        var ranges = [base.range]
        var strings = [base.string]
        var label = base.label
        if let end {
            ranges.append(end.range)
            strings.append(end.string)
            label += " · \(end.label)"
        }
        return Match(ranges: ranges, strings: strings, rule: rule, label: label)
    }

    private static func baseRecurrence(in text: String) -> Base? {
        // "every 2 weeks" / "every other day" → an interval > 1.
        if let found = captureMatch("\\bevery (\\d+|other) (day|week|month|year)s?\\b", in: text),
           found.captures.count >= 2 {
            let interval = found.captures[0].lowercased() == "other" ? 2 : max(2, Int(found.captures[0]) ?? 2)
            let unit = found.captures[1].lowercased()
            let frequency: EKRecurrenceFrequency =
                unit.hasPrefix("d") ? .daily : unit.hasPrefix("w") ? .weekly : unit.hasPrefix("y") ? .yearly : .monthly
            return Base(frequency: frequency, days: nil, interval: interval,
                        label: "Every \(interval) \(unit)s", range: found.range, string: found.string)
        }
        for weekday in weekdays {
            if let found = firstMatch("\\bevery (\(weekday.names))\\b", in: text) {
                return Base(frequency: .weekly, days: [weekday.day],
                            label: "Weekly on \(weekday.label)", range: found.range, string: found.string)
            }
        }
        if let found = firstMatch("\\b(every weekday|weekdays)\\b", in: text) {
            return Base(frequency: .weekly, days: [.monday, .tuesday, .wednesday, .thursday, .friday],
                        label: "Every weekday", range: found.range, string: found.string)
        }
        let frequencies: [(regex: String, freq: EKRecurrenceFrequency, label: String)] = [
            ("\\b(every day|daily)\\b", .daily, "Daily"),
            ("\\b(every week|weekly)\\b", .weekly, "Weekly"),
            ("\\b(every month|monthly)\\b", .monthly, "Monthly"),
            ("\\b(every year|yearly|annually)\\b", .yearly, "Yearly")
        ]
        for frequency in frequencies {
            if let found = firstMatch(frequency.regex, in: text) {
                return Base(frequency: frequency.freq, days: nil,
                            label: frequency.label, range: found.range, string: found.string)
            }
        }
        return nil
    }

    private static func endClause(in text: String) -> End? {
        // "for N times" → a fixed number of occurrences.
        if let found = captureMatch("\\bfor (\\d+) (?:times?|occurrences?)\\b", in: text),
           let count = Int(found.captures.first ?? "") {
            return End(recurrenceEnd: EKRecurrenceEnd(occurrenceCount: count),
                       label: "×\(count)", range: found.range, string: found.string)
        }
        // "for N days/weeks/months/years" → an end date that far out.
        if let found = captureMatch("\\bfor (\\d+) (days?|weeks?|months?|years?)\\b", in: text),
           found.captures.count >= 2, let amount = Int(found.captures[0]),
           let endDate = Calendar.current.date(byAdding: component(for: found.captures[1]), value: amount, to: Date()) {
            return End(recurrenceEnd: EKRecurrenceEnd(end: endDate),
                       label: "for \(amount) \(found.captures[1])", range: found.range, string: found.string)
        }
        // "until <weekday>" → ends on that weekday's next occurrence.
        for weekday in weekdays {
            if let found = firstMatch("\\buntil (\(weekday.names))\\b", in: text),
               let endDate = nextDate(of: weekday.day) {
                return End(recurrenceEnd: EKRecurrenceEnd(end: endDate),
                           label: "until \(weekday.label)", range: found.range, string: found.string)
            }
        }
        return nil
    }

    private static func makeRule(frequency: EKRecurrenceFrequency, days: [EKWeekday]?, interval: Int, end: EKRecurrenceEnd?) -> EKRecurrenceRule {
        if let days {
            return EKRecurrenceRule(
                recurrenceWith: .weekly,
                interval: interval,
                daysOfTheWeek: days.map { EKRecurrenceDayOfWeek($0) },
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: end
            )
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
    }

    private static func component(for unit: String) -> Calendar.Component {
        let unit = unit.lowercased()
        if unit.hasPrefix("d") { return .day }
        if unit.hasPrefix("w") { return .weekOfYear }
        if unit.hasPrefix("y") { return .year }
        return .month
    }

    private static func nextDate(of weekday: EKWeekday) -> Date? {
        var components = DateComponents()
        components.weekday = weekday.rawValue
        return Calendar.current.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> (range: NSRange, string: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return (match.range, String(text[range]))
    }

    private static func captureMatch(_ pattern: String, in text: String) -> (range: NSRange, string: String, captures: [String])? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let fullRange = Range(match.range, in: text) else {
            return nil
        }
        var captures: [String] = []
        for i in 1..<match.numberOfRanges {
            if let captureRange = Range(match.range(at: i), in: text) {
                captures.append(String(text[captureRange]))
            }
        }
        return (match.range, String(text[fullRange]), captures)
    }
}
