import SwiftUI
import EventKit

struct ContentView: View {
    @EnvironmentObject var remindersData: RemindersData
    @ObservedObject var userPreferences = UserPreferences.shared
    @State private var appHasPopoverOpen = false

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
    }

    // MARK: - Content subviews

    @ViewBuilder private var emptyStateContent: some View {
        NoReminderListsView()
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var filteredRemindersContent: some View {
        List {
            if userPreferences.showUpcomingReminders {
                Section(header: CalendarTitle(
                    title: userPreferences.upcomingRemindersInterval.sectionTitle,
                    color: .rmbColor(.upcomingSectionTitle),
                    icon: {
                        if userPreferences.filterUpcomingRemindersByCalendar {
                            Image(rmbSymbol: .filterCircle)
                                .help(rmbLocalized(.upcomingRemindersFilterByCalendarEnabledHelp))
                        }
                    }
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
                        ReminderItemView(reminderItem: reminderItem)
                    }
                }
                .modifier(ListSectionModifier())
            }
        }
        .modifier(ReminderListModifier(animationValue: remindersData.orderedFilteredSections))
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
            .padding(.bottom, 10)
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
    ContentView()
        .environmentObject(RemindersData())
}
