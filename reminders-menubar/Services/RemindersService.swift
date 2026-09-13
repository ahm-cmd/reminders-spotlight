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
    
    /// Returns whether the write actually landed. Callers that show the user a
    /// confirmation must check it — a swallowed failure means the entry is gone
    /// while the UI says it was saved.
    @discardableResult
    func save(reminder: EKReminder, tags: [Tag]? = nil) -> Bool {
        do {
            try eventStore.save(reminder, commit: true)
            // NOTE: Tags are persisted via REMSaveRequest directly.
            if #available(macOS 12, *), let tags {
                reminder.updateTags(tags)
            }
            return true
        } catch {
            print("Error saving reminder:", error.localizedDescription)
            return false
        }
    }
    
    /// nil when the write failed, so callers don't confirm a save that didn't happen.
    @discardableResult
    func createNew(with rmbReminder: RmbReminder, in calendar: EKCalendar, recurrence: EKRecurrenceRule? = nil) -> EKReminder? {
        let newReminder = EKReminder(eventStore: eventStore)
        newReminder.update(with: rmbReminder)
        newReminder.calendar = calendar
        if let recurrence {
            newReminder.recurrenceRules = [recurrence]
        }
        guard save(reminder: newReminder, tags: rmbReminder.tags) else { return nil }
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

    /// Incomplete reminders carrying none of `tags` — the Planner's unsorted tray,
    /// i.e. everything that hasn't been given a horizon yet.
    @available(macOS 12, *)
    func getReminders(withoutTags tags: [Tag]) async -> [ReminderItem] {
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let excluded = Set(tags.map { $0.name.lowercased() })
        let matching = await fetchReminders(matching: predicate).filter { reminder in
            reminder.ekTags.allSatisfy { !excluded.contains($0.name.lowercased()) }
        }
        return createReminderItems(for: matching).sortedUpcomingReminders
    }

    func remove(reminder: EKReminder) {
        do {
            try eventStore.remove(reminder, commit: true)
        } catch {
            print("Error removing reminder:", error.localizedDescription)
        }
    }
}

/// Loads and holds the Planner's data so the board can render the instant it's
/// opened.
///
/// Gathering it costs ~120ms of mostly main-thread work (EventKit reads tags
/// through Objective-C private selectors, once per reminder), which is very
/// visible if it starts when → is pressed: the board arrives empty and the push
/// animation stutters. Two things fix that — the cache outlives the panel (which
/// is rebuilt on every open), and it's warmed shortly after the bar appears, well
/// before → is likely to be pressed.
@MainActor
final class PlannerCache: ObservableObject {
    static let shared = PlannerCache()

    struct Snapshot {
        var tags: [Tag] = []
        var tagLists: [TagReminderList] = []
        var untagged: [ReminderItem] = []
        var completedToday = 0
        var streak = 0
        var isLoaded = false
    }

    @Published private(set) var snapshot = Snapshot()

    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var lastLoaded: Date?

    private init() {}

    /// Refresh only if the snapshot has gone stale. Opening the board right after
    /// the bar warmed it would otherwise repeat the whole ~120ms read on the main
    /// thread, during the push animation — the exact stutter the cache exists to
    /// avoid. Mutations call `refresh()` directly and always re-read.
    func refreshIfStale(maxAge: TimeInterval = 10) {
        guard let lastLoaded, Date().timeIntervalSince(lastLoaded) < maxAge else {
            refresh()
            return
        }
    }

    /// Refresh the snapshot. Overlapping calls coalesce: a request arriving while a
    /// pass is in flight queues exactly one more, so a burst of drops re-reads the
    /// store once at the end rather than once per drop.
    func refresh() {
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        refreshTask = Task { @MainActor in
            await reload()
            refreshTask = nil
            if refreshAgain {
                refreshAgain = false
                refresh()
            }
        }
    }

    private func reload() async {
        guard #available(macOS 12, *) else { return }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let since = calendar.date(byAdding: .day, value: -60, to: startOfToday) ?? startOfToday

        // Tags and completions don't depend on each other, so overlap them; the
        // two tag-scoped queries need the tag list and follow.
        async let tagsTask = RemindersService.shared.getAllTags()
        async let doneTask = RemindersService.shared.getCompletedReminders(since: since)
        let tags = await tagsTask
        let done = await doneTask

        async let listsTask = RemindersService.shared.getReminders(byTags: tags, calendarIdentifiers: nil)
        async let unsortedTask = RemindersService.shared.getReminders(withoutTags: Self.rowTags(from: tags))
        let lists = await listsTask
        let unsorted = await unsortedTask

        let momentum = Self.momentum(from: done, startOfToday: startOfToday)
        snapshot = Snapshot(
            tags: tags,
            tagLists: lists,
            untagged: unsorted,
            completedToday: momentum.today,
            streak: momentum.streak,
            isLoaded: true
        )
        lastLoaded = Date()
        pruneItemOrder(keeping: lists, and: unsorted)
    }

    /// The tags acting as board rows — the curated order if there is one, else every
    /// tag. The unsorted tray is everything carrying none of them.
    private static func rowTags(from all: [Tag]) -> [Tag] {
        let curated = UserPreferences.shared.plannerTags
        guard !curated.isEmpty else { return all }
        return curated.compactMap { name in
            all.first { $0.name.lowercased() == name.lowercased() }
        }
    }

    private static func momentum(from done: [EKReminder], startOfToday: Date) -> (today: Int, streak: Int) {
        let calendar = Calendar.current
        let today = done.filter {
            guard let date = $0.completionDate else { return false }
            return calendar.isDate(date, inSameDayAs: startOfToday)
        }.count

        var completedDays = Set<Date>()
        for reminder in done {
            if let date = reminder.completionDate {
                completedDays.insert(calendar.startOfDay(for: date))
            }
        }
        // Count consecutive completed days ending today (or yesterday, so the streak
        // stays "alive" before you've finished anything today).
        var day = completedDays.contains(startOfToday)
            ? startOfToday
            : (calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday)
        var streak = 0
        while completedDays.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return (today, streak)
    }

    /// Drop hand-placed positions for reminders that no longer exist (completed,
    /// deleted), so the stored order doesn't grow without bound.
    private func pruneItemOrder(keeping lists: [TagReminderList], and unsorted: [ReminderItem]) {
        let stored = UserPreferences.shared.plannerItemOrder
        guard !stored.isEmpty else { return }
        var alive = Set(unsorted.map { $0.reminder.calendarItemIdentifier })
        for list in lists {
            for item in list.reminders {
                alive.insert(item.reminder.calendarItemIdentifier)
            }
        }
        let pruned = stored.filter { alive.contains($0) }
        if pruned.count != stored.count {
            UserPreferences.shared.plannerItemOrder = pruned
        }
    }
}

/// Keeps a half-typed entry alive across a panel close, so stepping away to check
/// another app and re-opening the Spotlight resumes where you left off. Singleton
/// because the panel (and all its SwiftUI state) is rebuilt on every open.
///
/// Drafts are deliberately short-lived — after `lifetime` a forgotten entry is
/// dropped rather than resurfacing much later, when it's no longer what you meant
/// to write.
@MainActor
final class DraftCoordinator {
    static let shared = DraftCoordinator()

    struct Draft {
        let title: String
        let notes: String?
        let isEvent: Bool
    }

    /// How long a draft survives after the panel closes.
    private let lifetime: TimeInterval = 60

    private var draft: Draft?
    private var savedAt: Date?

    private init() {}

    /// Stash the in-progress entry. An empty title means there's nothing worth
    /// keeping, which also clears any older draft.
    func save(title: String, notes: String?, isEvent: Bool) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clear()
            return
        }
        draft = Draft(title: title, notes: notes, isEvent: isEvent)
        savedAt = Date()
    }

    /// The pending draft if one is still fresh, consuming it either way (an expired
    /// draft is discarded rather than left to linger).
    func take() -> Draft? {
        defer { clear() }
        guard let draft, let savedAt, Date().timeIntervalSince(savedAt) < lifetime else {
            return nil
        }
        return draft
    }

    func clear() {
        draft = nil
        savedAt = nil
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
