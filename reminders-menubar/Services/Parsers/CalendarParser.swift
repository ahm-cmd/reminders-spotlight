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
