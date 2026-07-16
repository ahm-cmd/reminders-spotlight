import EventKit

@MainActor
class RemindersService {
    static let shared = RemindersService()
    
    private init() {
        // This prevents others from using the default '()' initializer for this class.
    }
    
    private let eventStore = EKEventStore()
    
    var isAuthorized: Bool {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        } else {
            return EKEventStore.authorizationStatus(for: .reminder) == .authorized
        }
    }
    
    func requestAccess(completion: @escaping (Bool, String?) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { granted, error in
                completion(granted, error?.localizedDescription)
            }
        } else {
            eventStore.requestAccess(to: .reminder) { granted, error in
                completion(granted, error?.localizedDescription)
            }
        }
    }
    
    func getCalendar(withIdentifier calendarIdentifier: String) -> EKCalendar? {
        return eventStore.calendar(withIdentifier: calendarIdentifier)
    }

    // MARK: - Calendar events

    var isCalendarAuthorized: Bool {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        } else {
            return EKEventStore.authorizationStatus(for: .event) == .authorized
        }
    }

    func requestCalendarAccess(completion: @escaping (Bool, String?) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, error in
                completion(granted, error?.localizedDescription)
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                completion(granted, error?.localizedDescription)
            }
        }
    }

    func getEventCalendars() -> [EKCalendar] {
        return eventStore.calendars(for: .event).filter { $0.allowsContentModifications }
    }

    /// All event calendars the user can see (including read-only ones like
    /// holidays). Used for the agenda's calendar filter.
    func getAllEventCalendars() -> [EKCalendar] {
        guard isCalendarAuthorized else { return [] }
        return eventStore.calendars(for: .event)
    }

    func getDefaultEventCalendar() -> EKCalendar? {
        return eventStore.defaultCalendarForNewEvents ?? getEventCalendars().first
    }

    /// Upcoming events across all calendars for the next `days` days, sorted by
    /// start. Includes read-only calendars (e.g. holidays) so the list is complete.
    func getUpcomingEvents(days: Int = 14) -> [EKEvent] {
        guard isCalendarAuthorized else { return [] }
        let start = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    /// Creates a calendar event from the parsed entry. When a time was parsed the
    /// event runs one hour from that time; otherwise it's an all-day event on the
    /// parsed (or current) day.
    @discardableResult
    func createNewEvent(
        title: String,
        date: Date,
        hasTime: Bool,
        duration: TimeInterval = 0,
        recurrence: EKRecurrenceRule? = nil,
        notes: String? = nil,
        in calendar: EKCalendar
    ) -> EKEvent? {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.calendar = calendar
        event.notes = notes
        if hasTime {
            event.startDate = date
            event.endDate = date.addingTimeInterval(duration > 0 ? duration : 60 * 60)
            event.isAllDay = false
        } else {
            event.startDate = Calendar.current.startOfDay(for: date)
            event.endDate = event.startDate
            event.isAllDay = true
        }
        if let recurrence {
            event.recurrenceRules = [recurrence]
        }
        do {
            try eventStore.save(event, span: recurrence != nil ? .futureEvents : .thisEvent, commit: true)
            return event
        } catch {
            print("Failed to save event: \(error.localizedDescription)")
            return nil
        }
    }

    func remove(event: EKEvent) {
        do {
            try eventStore.remove(event, span: .thisEvent, commit: true)
        } catch {
            print("Failed to remove event: \(error.localizedDescription)")
        }
    }

    func getCalendars() -> [EKCalendar] {
        return eventStore.calendars(for: .reminder)
    }
    
    func getDefaultCalendar() -> EKCalendar? {
        return eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first
    }
    
    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { allReminders in
                guard let allReminders else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: allReminders)
            }
        }
    }

    private func createReminderItems(for calendarReminders: [EKReminder]) -> [ReminderItem] {
        var reminderItems: [ReminderItem] = []
        
        let noParentKey = "noParentKey"
        let remindersByParentId = Dictionary(grouping: calendarReminders, by: { $0.parentId ?? noParentKey })
        let parentReminders = remindersByParentId[noParentKey, default: []]
        
        parentReminders.forEach { parentReminder in
            let parentId = parentReminder.calendarItemIdentifier
            let children = remindersByParentId[parentId, default: []].map({ ReminderItem(for: $0, isChild: true) })
            reminderItems.append(ReminderItem(for: parentReminder, withChildren: children))
        }
        return reminderItems
    }

    func getReminders(of calendarIdentifiers: [String]) async -> [CalendarReminderList] {
        let calendars = getCalendars().filter({ calendarIdentifiers.contains($0.calendarIdentifier) })
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
        let remindersByCalendar = Dictionary(
            grouping: await fetchReminders(matching: predicate),
            by: { $0.calendar.calendarIdentifier }
        )

        var calendarReminderLists: [CalendarReminderList] = []
        for calendar in calendars {
            let calendarReminders = remindersByCalendar[calendar.calendarIdentifier, default: []]
            let reminderItems = createReminderItems(for: calendarReminders)
            calendarReminderLists.append(CalendarReminderList(for: calendar, with: reminderItems))
        }
        
        return calendarReminderLists
    }

    func getUpcomingReminders(
        _ interval: ReminderInterval,
        for calendarIdentifiers: [String]? = nil
    ) async -> [ReminderItem] {
        var calendars: [EKCalendar]?
        if let calendarIdentifiers {
            if calendarIdentifiers.isEmpty {
                // If the filter does not have any calendar selected, return empty
                return []
            }
            calendars = getCalendars().filter({ calendarIdentifiers.contains($0.calendarIdentifier) })
        }
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: interval.endingDate,
            calendars: calendars
        )
        var reminders = await fetchReminders(matching: predicate).map({ ReminderItem(for: $0) })
        if interval == .due {
            // For the 'due' interval, we should filter reminders for today with no time.
            // These will only be considered due/expired on the following day.
            reminders = reminders.filter { $0.reminder.isExpired }
        }
        return reminders.sortedUpcomingReminders
    }

    func getAllIncompleteRemindersCount(for calendarIdentifiers: [String]? = nil) async -> Int {
        var calendars: [EKCalendar]?
        if let calendarIdentifiers {
            if calendarIdentifiers.isEmpty {
                // If the filter does not have any calendar selected, return 0
                return 0
            }
            calendars = getCalendars().filter({ calendarIdentifiers.contains($0.calendarIdentifier) })
        }
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
        return await fetchReminders(matching: predicate).count
    }
    
    func save(reminder: EKReminder, tags: [Tag]? = nil) {
        do {
            try eventStore.save(reminder, commit: true)
            // NOTE: Tags are persisted via REMSaveRequest directly.
            if #available(macOS 12, *), let tags {
                reminder.updateTags(tags)
            }
        } catch {
            print("Error saving reminder:", error.localizedDescription)
        }
    }
    
    @discardableResult
    func createNew(with rmbReminder: RmbReminder, in calendar: EKCalendar, recurrence: EKRecurrenceRule? = nil) -> EKReminder {
        let newReminder = EKReminder(eventStore: eventStore)
        newReminder.update(with: rmbReminder)
        newReminder.calendar = calendar
        if let recurrence {
            newReminder.recurrenceRules = [recurrence]
        }
        save(reminder: newReminder, tags: rmbReminder.tags)
        return newReminder
    }
    
    func fetchAllReminders() async -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: nil)
        return await fetchReminders(matching: predicate)
    }

    /// Completed reminders with a completion date on/after `start` — used by the
    /// Planner's Momentum strip (today's count + streak).
    func getCompletedReminders(since start: Date) async -> [EKReminder] {
        let predicate = eventStore.predicateForCompletedReminders(
            withCompletionDateStarting: start,
            ending: nil,
            calendars: nil
        )
        return await fetchReminders(matching: predicate)
    }

    func getAllTags() async -> [Tag] {
        guard #available(macOS 12, *) else { return [] }

        let allReminders = await fetchAllReminders()
        var tags: Set<Tag> = []
        for reminder in allReminders {
            for tag in reminder.ekTags {
                tags.insert(tag)
            }
        }
        return tags.sorted()
    }

    @available(macOS 12, *)
    func getReminders(byTags tags: [Tag], calendarIdentifiers: [String]?) async -> [TagReminderList] {
        guard !tags.isEmpty else { return [] }

        var calendars: [EKCalendar]?
        if let calendarIdentifiers {
            if calendarIdentifiers.isEmpty {
                return []
            }
            calendars = getCalendars().filter({ calendarIdentifiers.contains($0.calendarIdentifier) })
        }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
        let allReminders = await fetchReminders(matching: predicate)

        var tagReminderLists: [TagReminderList] = []

        for tag in tags {
            let matchingReminders = allReminders.filter { reminder in
                reminder.ekTags.contains(tag)
            }
            let reminderItems = createReminderItems(for: matchingReminders)
            tagReminderLists.append(TagReminderList(for: tag, with: reminderItems))
        }

        return tagReminderLists
    }

    func remove(reminder: EKReminder) {
        do {
            try eventStore.remove(reminder, commit: true)
        } catch {
            print("Error removing reminder:", error.localizedDescription)
        }
    }
}

/// Holds the most recent reversible action (a created item to delete, or a
/// completed reminder to un-complete) so ⌘Z can undo it. Singleton so it
/// survives the panel closing and reopening.
@MainActor
final class UndoCoordinator {
    static let shared = UndoCoordinator()
    private var action: (() -> Void)?

    private init() {}

    var canUndo: Bool { action != nil }

    func register(_ action: @escaping () -> Void) {
        self.action = action
    }

    func performUndo() {
        guard let action else { return }
        self.action = nil
        action()
    }
}
