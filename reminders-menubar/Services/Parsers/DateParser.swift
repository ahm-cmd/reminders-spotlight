import Foundation

class DateParser {
    static let shared = DateParser()
    
    private let detector: NSDataDetector?
    
    struct TextDateResult {
        // A date can come from more than one token (e.g. "tomorrow … 9am"), so we
        // keep every matched range/substring.
        let ranges: [NSRange]
        let strings: [String]

        var highlightedTexts: [RmbHighlightedTextField.HighlightedText] {
            ranges.map { RmbHighlightedTextField.HighlightedText(range: $0, color: RmbColor.dateHighlight.nsColor) }
        }

        /// The first matched token (used for the "did the user already set a date"
        /// emptiness checks).
        var string: String { strings.first ?? "" }

        init() {
            self.ranges = []
            self.strings = []
        }

        init(range: NSRange, string: String) {
            self.ranges = [range]
            self.strings = [string]
        }

        init(ranges: [NSRange], strings: [String]) {
            self.ranges = ranges
            self.strings = strings
        }
    }
    
    struct DateParserResult {
        let date: Date
        let hasTime: Bool
        let isTimeOnly: Bool
        let textDateResult: TextDateResult
        /// Detected span in seconds when the text implies a range (e.g. "12–1pm");
        /// 0 when no duration was parsed. Used for calendar-event end times.
        var duration: TimeInterval = 0
    }
    
    private init() {
        // This prevents others from using the default '()' initializer for this class.
        let types: NSTextCheckingResult.CheckingType = [.date]
        detector = try? NSDataDetector(types: types.rawValue)
    }
    
    private func adjustDateAccordingToNow(_ dateResult: DateParserResult) -> DateParserResult? {
        // NOTE: Date will be adjusted only if it is in the past further than the day before yesterday.
        guard dateResult.date.isPast
                && !dateResult.date.isToday
                && !dateResult.date.isYesterday
                && !dateResult.date.isDayBeforeYesterday else {
            return dateResult
        }
        
        // NOTE: If the date is set to a day in the current year, but it's past that day, then we assume it's next year.
        // "Do something on February 2nd" - when it's already March.
        if dateResult.date.isThisYear {
            return DateParserResult(
                date: .nextYear(of: dateResult.date),
                hasTime: dateResult.hasTime,
                isTimeOnly: dateResult.isTimeOnly,
                textDateResult: dateResult.textDateResult,
                duration: dateResult.duration
            )
        }
        
        // NOTE: If the date is not adjusted we will return it unchanged.
        return dateResult
    }
    
    private func isTimeSignificant(in match: NSTextCheckingResult) -> Bool {
        let timeIsSignificantKey = "timeIsSignificant"
        if match.responds(to: NSSelectorFromString(timeIsSignificantKey)) {
            return match.value(forKey: timeIsSignificantKey) as? Bool ?? false
        }
        return false
    }
    
    private func isTimeOnlyResult(in match: NSTextCheckingResult) -> Bool {
        let underlyingResultKey = "underlyingResult"
        if match.responds(to: NSSelectorFromString(underlyingResultKey)) {
            let underlyingResult = match.value(forKey: underlyingResultKey)
            let description = underlyingResult.debugDescription
            return description.contains("Time") && !description.contains("Date")
        }
        return false
    }
    
    func getDate(from textString: String) -> DateParserResult? {
        // Relative phrases ("in 20 minutes") + common phrases ("this weekend",
        // "end of month", "the 15th") first — NSDataDetector misses these.
        if let relative = relativeDate(from: textString) {
            return relative
        }
        if let phrase = phraseDate(from: textString) {
            return phrase
        }
        // "one week before august 15", "2 days after friday", "by monday" — anchor
        // to the real date and apply the offset. Must run before NSDataDetector,
        // which otherwise reads "before <date>" as a vague expression and returns
        // today, swallowing the actual date.
        if let offset = relativeOffsetDate(from: textString) {
            return offset
        }

        let range = NSRange(textString.startIndex..., in: textString)

        let matches = detector?.matches(in: textString, options: [], range: range) ?? []
        guard let match = matches.first, var date = match.date else {
            return nil
        }

        var hasTime = isTimeSignificant(in: match)
        // isTimeOnlyResult materializes a private object's debugDescription, which
        // is costly to run on every keystroke. A time-only result by definition
        // has a significant time, so skip it entirely when there's no time.
        var isTimeOnly = hasTime && isTimeOnlyResult(in: match)
        var ranges = [match.range]
        var strings = [textString.substring(in: match.range)]
        var duration = match.duration

        // If the primary match has a day but no time, fold in a later, separate
        // time token — so "tomorrow text rob 9am" reads as tomorrow at 9am, not
        // just tomorrow with "9am" left in the title.
        if !hasTime {
            for other in matches.dropFirst() {
                guard let otherDate = other.date, isTimeSignificant(in: other) else {
                    continue
                }
                date = merge(day: date, time: otherDate)
                hasTime = true
                isTimeOnly = false
                ranges.append(other.range)
                strings.append(textString.substring(in: other.range))
                if duration == 0 { duration = other.duration }
                break
            }
        }

        let textDateResult = TextDateResult(ranges: ranges, strings: strings)

        let dateResult = DateParserResult(
            date: date,
            hasTime: hasTime,
            isTimeOnly: isTimeOnly,
            textDateResult: textDateResult,
            duration: duration
        )

        return adjustDateAccordingToNow(dateResult)
    }

    /// Parses "in N minutes / hours / days / weeks / months" → now + offset.
    /// Minutes/hours set a precise time; larger units land on the day.
    private func relativeDate(from textString: String) -> DateParserResult? {
        let pattern = "\\bin\\s+(\\d+)\\s+(minutes?|mins?|hours?|hrs?|days?|weeks?|months?)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(textString.startIndex..., in: textString)
        guard let match = regex.firstMatch(in: textString, options: [], range: nsRange),
              let amountRange = Range(match.range(at: 1), in: textString),
              let unitRange = Range(match.range(at: 2), in: textString),
              let amount = Int(textString[amountRange]) else {
            return nil
        }

        let unit = textString[unitRange].lowercased()
        let component: Calendar.Component
        let hasTime: Bool
        if unit.hasPrefix("min") {
            component = .minute; hasTime = true
        } else if unit.hasPrefix("h") {
            component = .hour; hasTime = true
        } else if unit.hasPrefix("d") {
            component = .day; hasTime = false
        } else if unit.hasPrefix("w") {
            component = .weekOfYear; hasTime = false
        } else {
            component = .month; hasTime = false
        }

        guard let date = Calendar.current.date(byAdding: component, value: amount, to: Date()) else {
            return nil
        }

        let textDateResult = TextDateResult(
            range: match.range,
            string: textString.substring(in: match.range)
        )
        return DateParserResult(
            date: date,
            hasTime: hasTime,
            isTimeOnly: false,
            textDateResult: textDateResult,
            duration: 0
        )
    }

    /// Parses "[N unit] before/after/by <date>" → the base date shifted by the
    /// offset. "one week before august 15" → Aug 15 minus a week; a bare
    /// "before/by monday" → that date (offset 0). The base date is parsed by the
    /// normal path, so any date form works after the preposition.
    private func relativeOffsetDate(from textString: String) -> DateParserResult? {
        let prefix = "\\b(?:(\\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
            + "\\s+(day|week|month|year)s?\\s+)?(before|after|prior to|ahead of|by)\\s+"
        guard let regex = try? NSRegularExpression(pattern: prefix, options: [.caseInsensitive]) else {
            return nil
        }
        let full = NSRange(textString.startIndex..., in: textString)
        guard let match = regex.firstMatch(in: textString, options: [], range: full) else {
            return nil
        }

        // Everything after the "…before/after/by " prefix is the base date phrase.
        let prefixEnd = match.range.location + match.range.length
        guard prefixEnd < full.length,
              let restRange = Range(NSRange(location: prefixEnd, length: full.length - prefixEnd), in: textString) else {
            return nil
        }
        let restText = String(textString[restRange])
        guard let base = getDate(from: restText),
              let baseRange = base.textDateResult.ranges.first else {
            return nil
        }

        var amount = 0
        var component: Calendar.Component = .day
        if let quantityRange = Range(match.range(at: 1), in: textString),
           let unitRange = Range(match.range(at: 2), in: textString) {
            amount = number(from: String(textString[quantityRange]))
            component = calendarComponent(from: String(textString[unitRange]))
        }
        let preposition = Range(match.range(at: 3), in: textString).map { String(textString[$0]).lowercased() } ?? ""
        let signedAmount = preposition == "after" ? amount : -amount
        let shiftedDate = Calendar.current.date(byAdding: component, value: signedAmount, to: base.date) ?? base.date

        // Highlight/strip from the prefix start through the end of the base date,
        // leaving any trailing title text intact.
        let stripLength = match.range.length + baseRange.location + baseRange.length
        let stripRange = NSRange(location: match.range.location, length: stripLength)
        return DateParserResult(
            date: shiftedDate,
            hasTime: base.hasTime,
            isTimeOnly: false,
            textDateResult: TextDateResult(range: stripRange, string: textString.substring(in: stripRange)),
            duration: base.duration
        )
    }

    private func number(from text: String) -> Int {
        if let n = Int(text) { return n }
        switch text.lowercased() {
        case "a", "an", "one": return 1
        case "two": return 2
        case "three": return 3
        case "four": return 4
        case "five": return 5
        case "six": return 6
        case "seven": return 7
        case "eight": return 8
        case "nine": return 9
        case "ten": return 10
        case "eleven": return 11
        case "twelve": return 12
        default: return 1
        }
    }

    private func calendarComponent(from unit: String) -> Calendar.Component {
        switch unit.lowercased() {
        case "week": return .weekOfYear
        case "month": return .month
        case "year": return .year
        default: return .day
        }
    }

    /// Parses common phrases NSDataDetector misses: "this/next weekend",
    /// "end of (the) month", "(on) the 15th".
    private func phraseDate(from textString: String) -> DateParserResult? {
        let calendar = Calendar.current
        let now = Date()
        let fullRange = NSRange(textString.startIndex..., in: textString)

        // "this weekend" / "next weekend" → the upcoming Saturday.
        if let regex = try? NSRegularExpression(pattern: "\\b(this|next) weekend\\b", options: [.caseInsensitive]),
           let match = regex.firstMatch(in: textString, options: [], range: fullRange) {
            let isNext = textString.substring(in: match.range).lowercased().hasPrefix("next")
            var components = DateComponents()
            components.weekday = 7   // Saturday
            if var saturday = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) {
                if isNext { saturday = calendar.date(byAdding: .weekOfYear, value: 1, to: saturday) ?? saturday }
                return phraseResult(saturday, range: match.range, in: textString)
            }
        }

        // "end of (the) month" → the last day of the current month.
        if let regex = try? NSRegularExpression(pattern: "\\bend of (?:the )?month\\b", options: [.caseInsensitive]),
           let match = regex.firstMatch(in: textString, options: [], range: fullRange),
           let monthDays = calendar.range(of: .day, in: .month, for: now),
           let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
           let lastDay = calendar.date(byAdding: DateComponents(day: monthDays.count - 1), to: firstOfMonth) {
            return phraseResult(lastDay, range: match.range, in: textString)
        }

        // "(on) the 15th" → that day this month, or next month if already past.
        if let regex = try? NSRegularExpression(pattern: "\\b(?:on )?the (\\d{1,2})(?:st|nd|rd|th)\\b", options: [.caseInsensitive]),
           let match = regex.firstMatch(in: textString, options: [], range: fullRange),
           let dayRange = Range(match.range(at: 1), in: textString),
           let day = Int(textString[dayRange]), (1...31).contains(day) {
            var components = calendar.dateComponents([.year, .month], from: now)
            components.day = day
            if let candidate = calendar.date(from: components) {
                let target = candidate < calendar.startOfDay(for: now)
                    ? (calendar.date(byAdding: .month, value: 1, to: candidate) ?? candidate)
                    : candidate
                return phraseResult(target, range: match.range, in: textString)
            }
        }

        return nil
    }

    private func phraseResult(_ date: Date, range: NSRange, in text: String) -> DateParserResult {
        DateParserResult(
            date: date,
            hasTime: false,
            isTimeOnly: false,
            textDateResult: TextDateResult(range: range, string: text.substring(in: range)),
            duration: 0
        )
    }

    /// Combines the calendar day of `day` with the time-of-day of `time`.
    private func merge(day: Date, time: Date) -> Date {
        let calendar = Calendar.current
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: time)
        var merged = DateComponents()
        merged.year = dayComponents.year
        merged.month = dayComponents.month
        merged.day = dayComponents.day
        merged.hour = timeComponents.hour
        merged.minute = timeComponents.minute
        merged.second = timeComponents.second
        return calendar.date(from: merged) ?? day
    }
    
    func getTimeOnly(from textString: String, on date: Date) -> DateParserResult? {
        guard let dateResult = getDate(from: textString),
              dateResult.date.isSameDay(as: date) || dateResult.isTimeOnly,
              dateResult.hasTime else {
            return nil
        }
        
        return dateResult
    }
}
