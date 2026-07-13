import SwiftUI
import Combine
import EventKit

@MainActor
class RemindersData: ObservableObject {
    private var cancellationTokens: [AnyCancellable] = []
    private let previewService = MenuBarPreviewService()

    init() {
        addObservers()
        Task {
            await update()
        }
    }

    private func addObservers() {
        addDataObservers()
        addUpcomingObservers()
        addTagObservers()
        addMenuBarObservers()
    }

    private func addDataObservers() {
        Publishers.MergeMany(
            NotificationCenter.default.publisher(for: .EKEventStoreChanged),
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged),
            NotificationCenter.default.publisher(for: .remindersDataShouldUpdate)
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            Task {
                await self?.update()
            }
        }
        .store(in: &cancellationTokens)

        Publishers.MergeMany(
            UserPreferences.shared.$showRemindersWithDueDateOnTop.map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$sortRemindersByPriority.map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$reminderSortingOrder.map { _ in }.eraseToAnyPublisher(),
            $calendarIdentifiersFilter.removeDuplicates().map { _ in }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { [weak self] _ in
            Task {
                await self?.update()
            }
        }
        .store(in: &cancellationTokens)
    }

    private func addUpcomingObservers() {
        Publishers.MergeMany(
            UserPreferences.shared.$upcomingRemindersInterval.map { _ in }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { [weak self] _ in
            Task {
                guard let self else { return }
                self.upcomingReminders = await self.getUpcomingReminders()
            }
        }
        .store(in: &cancellationTokens)
    }

    private func addTagObservers() {
        Publishers.MergeMany(
            $tagsFilter.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$filterTagRemindersByCalendar.map { _ in }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { [weak self] _ in
            Task {
                guard let self else { return }
                self.filteredTagReminderLists = await self.getTagReminders()
            }
        }
        .store(in: &cancellationTokens)
    }

    private func addMenuBarObservers() {
        UserPreferences.shared.$menuBarCounterType
            .dropFirst()
            .sink { [weak self] _ in
                Task {
                    guard let self else { return }
                    self.updateMenuBarCount(to: await self.getMenuBarCount())
                }
            }
            .store(in: &cancellationTokens)

        UserPreferences.shared.$filterMenuBarContentByCalendar
            .dropFirst()
            .sink { [weak self] _ in
                Task {
                    guard let self else { return }
                    self.updateMenuBarCount(to: await self.getMenuBarCount())
                    await self.refreshPreview()
                }
            }
            .store(in: &cancellationTokens)

        UserPreferences.shared.$menuBarReminderPreviewEnabled
            .dropFirst()
            .sink { [weak self] _ in
                Task {
                    guard let self else { return }
                    await self.refreshPreview()
                }
            }
            .store(in: &cancellationTokens)

        Publishers.MergeMany(
            UserPreferences.shared.$reminderMenuBarIcon.map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$hideMenuBarIconWhenContentIsShown.map { _ in }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { _ in
            AppDelegate.shared.loadMenuBarIcon()
        }
        .store(in: &cancellationTokens)
    }

    @Published var availableCalendars: [EKCalendar] = []

    @Published var availableTags: [Tag] = []

    @Published var upcomingReminders: [ReminderItem] = []

    @Published private var filteredCalendarReminderLists: [CalendarReminderList] = []

    @Published private var filteredTagReminderLists: [TagReminderList] = []

    var orderedFilteredSections: [ReminderListSection] {
        let calendarSections = filteredCalendarReminderLists.map { ReminderListSection.calendar($0) }
        let tagSections = filteredTagReminderLists.map { ReminderListSection.tag($0) }

        if UserPreferences.shared.showTagsBeforeCalendars {
            return tagSections + calendarSections
        }
        return calendarSections + tagSections
    }

    @Published var calendarIdentifiersFilter: [String] = {
        guard let identifiers = UserPreferences.shared.preferredCalendarIdentifiersFilter else {
            // NOTE: On first use it will load all reminder lists.
            let allCalendars = RemindersService.shared.getCalendars()
            return allCalendars.map({ $0.calendarIdentifier })
        }

        return identifiers
    }() {
        didSet {
            UserPreferences.shared.preferredCalendarIdentifiersFilter = calendarIdentifiersFilter
        }
    }

    @Published var tagsFilter: [Tag] = {
        return (UserPreferences.shared.preferredTagsFilter ?? []).map { Tag($0) }
    }() {
        didSet {
            UserPreferences.shared.preferredTagsFilter = tagsFilter.map(\.name)
        }
    }

    @Published var pendingNewReminderTitle: String?

    @Published var calendarForSaving: EKCalendar? = {
        guard RemindersService.shared.isAuthorized else {
            return nil
        }

        guard let identifier = UserPreferences.shared.preferredCalendarIdentifierForSaving,
              let calendar = RemindersService.shared.getCalendar(withIdentifier: identifier) else {
            return RemindersService.shared.getDefaultCalendar()
        }

        return calendar
    }() {
        didSet {
            let identifier = calendarForSaving?.calendarIdentifier
            UserPreferences.shared.preferredCalendarIdentifierForSaving = identifier
        }
    }

    func update() async {
        // Validate filter — remove stale calendars that no longer exist
        let calendars = RemindersService.shared.getCalendars()
        // EventKit can transiently return zero calendars right after the store
        // changes/reloads. Don't let that wipe availableCalendars + the filter
        // (which blanks the UI until the next refresh) — skip this cycle instead.
        if calendars.isEmpty && !availableCalendars.isEmpty && RemindersService.shared.isAuthorized {
            return
        }
        let calendarsSet = Set(calendars.map({ $0.calendarIdentifier }))
        self.availableCalendars = calendars
        self.calendarIdentifiersFilter = self.calendarIdentifiersFilter.filter({ calendarsSet.contains($0) })
        CalendarParser.updateShared(with: calendars)

        // Validate filter — remove stale tags that no longer exist
        if #available(macOS 12, *) {
            let tags = await RemindersService.shared.getAllTags()
            self.availableTags = tags
            self.tagsFilter = self.tagsFilter.filter({ tags.contains($0) })
            TagParser.updateShared(with: tags)
        }

        // Fetch reminder data with validated filters. These are independent
        // EventKit reads, so run them concurrently rather than serially —
        // refresh latency becomes the slowest fetch, not the sum of all of them.
        async let calendarLists = RemindersService.shared.getReminders(of: self.calendarIdentifiersFilter)
        async let upcoming = getUpcomingReminders()
        async let tagLists = getTagReminders()
        async let menuBarCount = getMenuBarCount()
        async let previewDone: Void = refreshPreview()

        self.filteredCalendarReminderLists = await calendarLists
        self.upcomingReminders = await upcoming
        self.filteredTagReminderLists = await tagLists
        self.updateMenuBarCount(to: await menuBarCount)
        _ = await previewDone
    }
    
    private func getUpcomingReminders() async -> [ReminderItem] {
        // Upcoming/overdue reminders always honor the list filter, so hiding a
        // list hides its reminders everywhere — including overdue ones.
        return await RemindersService.shared.getUpcomingReminders(
            UserPreferences.shared.upcomingRemindersInterval,
            for: self.calendarIdentifiersFilter
        )
    }

    private func getTagReminders() async -> [TagReminderList] {
        guard #available(macOS 12, *) else { return [] }
        guard !tagsFilter.isEmpty else { return [] }

        let calendarFilter = UserPreferences.shared.filterTagRemindersByCalendar
            ? self.calendarIdentifiersFilter
            : nil

        return await RemindersService.shared.getReminders(
            byTags: self.tagsFilter,
            calendarIdentifiers: calendarFilter
        )
    }

    private func getMenuBarCount() async -> Int {
        let calendarFilter = UserPreferences.shared.filterMenuBarContentByCalendar
            ? self.calendarIdentifiersFilter
            : nil

        switch UserPreferences.shared.menuBarCounterType {
        case .due:
            return await RemindersService.shared.getUpcomingReminders(.due, for: calendarFilter).count
        case .today:
            return await RemindersService.shared.getUpcomingReminders(.today, for: calendarFilter).count
        case .allReminders:
            // getUpcomingReminders only returns dated reminders. `.allReminders` must include reminders with no due date.
            return await RemindersService.shared.getAllIncompleteRemindersCount(for: calendarFilter)
        case .disabled:
            return -1
        }
    }

    private func updateMenuBarCount(to count: Int) {
        AppDelegate.shared.updateMenuBarCount(to: count)
    }

    private func refreshPreview() async {
        let calendarFilter = UserPreferences.shared.filterMenuBarContentByCalendar
            ? calendarIdentifiersFilter
            : nil
        await previewService.refresh(calendarFilter: calendarFilter)
    }

    func optimisticallyRemove(reminderItem: ReminderItem) {
        let idsToRemove = Set([reminderItem.id] + reminderItem.childReminders.map(\.id))

        filteredCalendarReminderLists = filteredCalendarReminderLists.map { list in
            let filtered = list.reminders.filter { !idsToRemove.contains($0.id) }
            return CalendarReminderList(for: list.calendar, with: filtered)
        }

        filteredTagReminderLists = filteredTagReminderLists.map { list in
            let filtered = list.reminders.filter { !idsToRemove.contains($0.id) }
            return TagReminderList(for: list.tag, with: filtered)
        }

        upcomingReminders = upcomingReminders.filter { !idsToRemove.contains($0.id) }
    }
}
