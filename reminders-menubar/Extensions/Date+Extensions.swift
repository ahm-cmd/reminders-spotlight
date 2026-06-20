import Foundation

/// Caches fully-configured `DateFormatter`s keyed by locale + configuration.
/// Creating a `DateFormatter` is one of the most expensive Foundation
/// operations; the cached instances are only ever read (`string(from:)`), which
/// is thread-safe on modern macOS, so they're never mutated after building.
private final class RmbDateFormatterCache {
    static let shared = RmbDateFormatterCache()
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]

    func formatter(forKey key: String, build: () -> DateFormatter) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] {
            return cached
        }
        let formatter = build()
        formatters[key] = formatter
        return formatter
    }
}

extension Date {
    var isPast: Bool {
        return self.timeIntervalSinceNow < 0
    }
    
    var isToday: Bool {
        return Calendar.current.isDateInToday(self)
    }
    
    var isYesterday: Bool {
        return Calendar.current.isDateInYesterday(self)
    }
    
    var isDayBeforeYesterday: Bool {
        let dayBeforeYesterday = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? self
        return self.isSameDay(as: dayBeforeYesterday)
    }
                                                                   
    var isThisYear: Bool {
        return Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
    }
    
    var elapsedTimeInterval: TimeInterval {
        return Date().timeIntervalSince(self)
    }
    
    static func nextExactHour(of date: Date = Date(), allowDayChange: Bool = false) -> Date {
        let today = Date()
        let todayNextHour = Calendar.current.date(byAdding: .hour, value: 1, to: today)!
        let isNextHourChangingDay = !todayNextHour.isToday
        
        var hourComponent = Calendar.current.dateComponents([.hour], from: today)
        if allowDayChange || !isNextHourChangingDay {
            hourComponent.hour! += 1
        }
        
        let dateWithoutTime = Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: date)!
        return Calendar.current.date(byAdding: hourComponent, to: dateWithoutTime)!
    }
    
    static func nextYear(of date: Date = Date()) -> Date {
        return Calendar.current.date(byAdding: .year, value: 1, to: date) ?? date
    }
    
    func isSameDay(as otherDate: Date) -> Bool {
        return Calendar.current.isDate(self, inSameDayAs: otherDate)
    }
    
    func relativeDateDescription(withTime showTimeDescription: Bool) -> String {
        return dateDescription(withTime: showTimeDescription, relativeFormatting: true)
    }

    func absoluteDateDescription(withTime showTimeDescription: Bool) -> String {
        return dateDescription(withTime: showTimeDescription, relativeFormatting: false)
    }

    private func dateDescription(withTime showTimeDescription: Bool, relativeFormatting: Bool) -> String {
        let locale = rmbTimeFormattedLocale()

        // Reuse cached formatters — `DateFormatter()` is very expensive to
        // create, and this runs for every reminder row's due-date label.
        let dateFormatter = RmbDateFormatterCache.shared.formatter(
            forKey: "date|\(locale.identifier)|rel:\(relativeFormatting)"
        ) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.locale = locale
            formatter.doesRelativeDateFormatting = relativeFormatting
            return formatter
        }
        let dateString = dateFormatter.string(from: self)

        guard showTimeDescription else {
            return dateString
        }

        let timeFormatter = RmbDateFormatterCache.shared.formatter(
            forKey: "time|\(locale.identifier)"
        ) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .none
            formatter.doesRelativeDateFormatting = false
            // NOTE: "jm" adapts hour format (12h/24h) to the locale's hour cycle preference
            formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: locale)
            return formatter
        }
        let timeString = timeFormatter.string(from: self)

        return "\(dateString), \(timeString)"
    }
    
    func dateComponents(withTime: Bool) -> DateComponents {
        var components: Set<Calendar.Component> = [.calendar, .era, .year, .month, .day]
        if withTime {
            components.formUnion([.timeZone, .hour, .minute, .second])
        }
        return Calendar.current.dateComponents(components, from: self)
    }
}
