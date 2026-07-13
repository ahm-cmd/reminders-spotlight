import SwiftUI
import EventKit

struct ContentView: View {
    @EnvironmentObject var remindersData: RemindersData
    @ObservedObject var userPreferences = UserPreferences.shared
    @Binding var scrolledDown: Bool
    @State private var appHasPopoverOpen = false
    @State private var selectedIndex = -1   // keyboard selection over flatReminders; -1 = none, so no row is pre-highlighted on open

    /// Flat, ordered reminders across the visible list sections (keyboard nav).
    private var flatReminders: [ReminderItem] {
        remindersData.orderedFilteredSections.flatMap { $0.reminders }
    }

    private var selectedReminder: ReminderItem? {
        flatReminders.indices.contains(selectedIndex) ? flatReminders[selectedIndex] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if remindersData.availableCalendars.isEmpty {
                emptyStateContent
            } else if userPreferences.atLeastOneFilterIsSelected {
                filteredRemindersContent
            } else {
                noFilterContent
            }
        }
        .environment(\.appHasPopoverOpen, $appHasPopoverOpen)
        .onReceive(NotificationCenter.default.publisher(for: .panelNavigateUp)) { _ in moveSelection(-1) }
        .onReceive(NotificationCenter.default.publisher(for: .panelNavigateDown)) { _ in moveSelection(1) }
        .onReceive(NotificationCenter.default.publisher(for: .panelActivateSelection)) { _ in completeSelected() }
    }

    private func moveSelection(_ delta: Int) {
        guard !flatReminders.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), flatReminders.count - 1)
    }

    private func completeSelected() {
        guard let item = selectedReminder, !item.reminder.isCompleted else { return }
        item.reminder.isCompleted = true
        SoundService.shared.playCompleteChime()
        RemindersService.shared.save(reminder: item.reminder)

        let completed = item.reminder
        UndoCoordinator.shared.register {
            completed.isCompleted = false
            RemindersService.shared.save(reminder: completed)
            NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
        }
        remindersData.optimisticallyRemove(reminderItem: item)
        selectedIndex = min(selectedIndex, max(flatReminders.count - 1, 0))
    }

    // MARK: - Content subviews

    @ViewBuilder private var emptyStateContent: some View {
        NoReminderListsView()
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var filteredRemindersContent: some View {
        ScrollViewReader { proxy in
            List {
                if userPreferences.showUpcomingReminders {
                    Section(header: CalendarTitle(
                        title: userPreferences.upcomingRemindersInterval.sectionTitle,
                        color: .rmbColor(.upcomingSectionTitle),
                        icon: { EmptyView() }
                    )) {
                        UpcomingRemindersContent()
                    }
                    .modifier(ListSectionModifier())
                }

                ForEach(remindersData.orderedFilteredSections) { section in
                    Section(header: CalendarTitle(
                        title: section.title,
                        color: section.color,
                        icon: {
                            if case .tag = section, userPreferences.filterTagRemindersByCalendar {
                                Image(rmbSymbol: .filterCircle)
                                    .help(rmbLocalized(.tagRemindersFilterByCalendarEnabledHelp))
                            }
                        }
                    )) {
                        if section.reminders.isEmpty {
                            NoReminderItemsView(emptyList: .allItemsCompleted)
                        }
                        ForEach(section.reminders) { reminderItem in
                            ReminderItemView(
                                reminderItem: reminderItem,
                                isKeyboardSelected: reminderItem.id == selectedReminder?.id
                            )
                            .id(reminderItem.id)
                        }
                    }
                    .modifier(ListSectionModifier())
                }
            }
            .modifier(ReminderListModifier(animationValue: remindersData.orderedFilteredSections))
            .modifier(ScrollDownReporter(scrolledDown: $scrolledDown))
            .onChange(of: selectedIndex) { _ in
                if let id = selectedReminder?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder private var noFilterContent: some View {
        NoFilterSelectedView()
            .frame(maxHeight: .infinity)
    }
}

// MARK: - View Modifiers

struct ReminderListModifier<V: Equatable>: ViewModifier {
    let animationValue: V

    func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(.default, value: animationValue)
            .padding(.top, 12)      // breathing room above the first date heading
            .padding(.bottom, 10)
    }
}

/// Reports whether the reminders list has been scrolled down from the top, so
/// the floating filter/settings buttons can fade out and stop overlapping the
/// entries beneath them. No-op before macOS 15 (buttons simply stay put).
struct ScrollDownReporter: ViewModifier {
    @Binding var scrolledDown: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 8 } action: { _, isDown in
                if isDown != scrolledDown { scrolledDown = isDown }
            }
        } else {
            content
        }
    }
}

struct ListSectionModifier: ViewModifier {
    func body(content: Content) -> some View {
        let base = content
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            .padding(.horizontal, 12)

        if #available(macOS 13.0, *) {
            base.listRowSeparator(.hidden)
        } else {
            base
        }
    }
}

#Preview {
    ContentView(scrolledDown: .constant(false))
        .environmentObject(RemindersData())
}
