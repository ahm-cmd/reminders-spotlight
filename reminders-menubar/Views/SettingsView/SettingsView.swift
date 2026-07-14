import SwiftUI
import EventKit

enum SettingsTab: Hashable {
    case general
    case menuBar
    case reminders
    case keyboard
    case shortcuts
    case about
}

/// Reports the natural (unconstrained) height of the current settings tab so the
/// window can animate its bottom edge to fit each page.
private struct SettingsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SettingsView: View {
    @ObservedObject private var coordinator = SettingsCoordinator.shared
    @State private var displayHeight: CGFloat?

    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            GeneralSettingsTab()
                .tabItem {
                    Label(rmbLocalized(.generalSettingsTab), rmbSymbol: .gearshape)
                }
                .tag(SettingsTab.general)

            MenuBarSettingsTab()
                .tabItem {
                    Label(rmbLocalized(.menuBarSettingsTab), rmbSymbol: .menubarRectangle)
                }
                .tag(SettingsTab.menuBar)

            ReminderSettingsTab()
                .tabItem {
                    Label(rmbLocalized(.remindersSettingsTab), rmbSymbol: .listBullet)
                }
                .tag(SettingsTab.reminders)

            KeyboardSettingsTab()
                .tabItem {
                    Label(rmbLocalized(.keyboardSettingsTab), rmbSymbol: .keyboard)
                }
                .tag(SettingsTab.keyboard)

            ShortcutsSettingsTab()
                .tabItem {
                    Label(String("Shortcuts"), systemImage: "at")
                }
                .tag(SettingsTab.shortcuts)

            AboutSettingsTab()
                .tabItem {
                    Label(rmbLocalized(.aboutSettingsTab), rmbSymbol: .infoCircle)
                }
                .tag(SettingsTab.about)
        }
        .frame(width: 620)
        // Take the natural height of whichever tab is showing, and report it...
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SettingsHeightKey.self, value: proxy.size.height)
            }
        )
        // ...then constrain the window to an animated height so switching tabs eases
        // the bottom edge open/closed instead of snapping instantly.
        .frame(height: displayHeight, alignment: .top)
        .clipped()
        .onPreferenceChange(SettingsHeightKey.self) { newHeight in
            guard newHeight > 1 else { return }
            guard let current = displayHeight else {
                displayHeight = newHeight
                return
            }
            if abs(current - newHeight) > 0.5 {
                withAnimation(.easeOut(duration: 0.22)) {
                    displayHeight = newHeight
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}

// MARK: - Shortcuts

/// Holds three sections: `@` shortcuts that route a reminder to a list, `#`
/// shortcuts that expand a short key into a full tag, and `@` shortcuts that
/// route a calendar event to a calendar.
struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            // Wrap the sections in one VStack so Form treats them as a single view
            // rather than auto-interpreting each SettingsSection's label+content as
            // a form row (which trailing-aligns a section whose content leads with
            // text, e.g. an empty shortcut list).
            VStack(alignment: .leading, spacing: 0) {
                ListShortcutsSection()
                SettingsDivider()
                TagShortcutsSection()
                SettingsDivider()
                CalendarShortcutsSection()
            }
        }
        .padding(20)
    }
}

// MARK: - List Shortcuts

/// Lets the user define `@` shortcuts (e.g. "@p" → Personal) that, when typed
/// in the reminder field, are stripped from the text and assign that list.
struct ListShortcutsSection: View {
    @State private var entries: [ShortcutEntry] = []
    @State private var calendars: [EKCalendar] = []
    @State private var saveWork: DispatchWorkItem?

    struct ShortcutEntry: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var calendarId: String
    }

    var body: some View {
        SettingsSection(String("List Shortcuts")) {
            Text(String("Type a shortcut like “@p” in the reminder field. It’s removed from the "
                + "text and the reminder is assigned to the chosen list."))
                .modifier(SettingsNoteStyle())

            if calendars.isEmpty {
                Text(String("No reminder lists available."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach($entries) { $entry in
                    shortcutRow($entry)
                }

                Button {
                    entries.append(ShortcutEntry(key: "", calendarId: calendars.first?.calendarIdentifier ?? ""))
                } label: {
                    Label(String("Add Shortcut"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .onAppear {
            calendars = RemindersService.shared.getCalendars()
            load()
        }
        .onChange(of: entries) { _ in scheduleSave() }
    }

    private func shortcutRow(_ entry: Binding<ShortcutEntry>) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                Text(String("@")).foregroundStyle(.secondary)
                TextField(String("key"), text: entry.key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(String(""), selection: entry.calendarId) {
                ForEach(calendars, id: \.calendarIdentifier) { calendar in
                    Text(calendar.title).tag(calendar.calendarIdentifier)
                }
            }
            .labelsHidden()

            Spacer()

            Button {
                entries.removeAll { $0.id == entry.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String("Remove shortcut"))
        }
    }

    private func load() {
        entries = UserPreferences.shared.listShortcuts
            .map { ShortcutEntry(key: $0.key, calendarId: $0.value) }
            .sorted { $0.key < $1.key }
    }

    /// Debounce: typing in a shortcut key fires onChange per keystroke; coalesce
    /// so we persist + rebuild once the edits settle, not on every character.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func save() {
        var dict: [String: String] = [:]
        for entry in entries {
            let key = entry.key
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "@", with: "")
                .lowercased()
            guard !key.isEmpty, !entry.calendarId.isEmpty else { continue }
            dict[key] = entry.calendarId
        }
        UserPreferences.shared.listShortcuts = dict
        // Only the shortcut map changed, so rebuild just the parser — no need for
        // a full RemindersData.update() (5 EventKit fetches). The entry field
        // parses via CalendarParser, which reads this map.
        CalendarParser.updateShared(with: RemindersService.shared.getCalendars())
    }
}

// MARK: - Tag Shortcuts

/// Lets the user define `#` shortcuts (e.g. "#wp" → "work-project") that, when
/// typed in the reminder field, expand to the full tag and tag the reminder.
struct TagShortcutsSection: View {
    @State private var entries: [TagShortcutEntry] = []
    @State private var saveWork: DispatchWorkItem?

    struct TagShortcutEntry: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var tag: String
    }

    var body: some View {
        SettingsSection(String("Tag Shortcuts")) {
            Text(String("Type a shortcut like “#wp” in the reminder field. It expands to the full "
                + "tag (e.g. “work-project”) and tags the reminder."))
                .modifier(SettingsNoteStyle())

            ForEach($entries) { $entry in
                shortcutRow($entry)
            }

            Button {
                entries.append(TagShortcutEntry(key: "", tag: ""))
            } label: {
                Label(String("Add Shortcut"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .onAppear { load() }
        .onChange(of: entries) { _ in scheduleSave() }
    }

    private func shortcutRow(_ entry: Binding<TagShortcutEntry>) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                Text(String("#")).foregroundStyle(.secondary)
                TextField(String("key"), text: entry.key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 1) {
                Text(String("#")).foregroundStyle(.secondary)
                TextField(String("tag"), text: entry.tag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }

            Spacer()

            Button {
                entries.removeAll { $0.id == entry.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String("Remove shortcut"))
        }
    }

    private func load() {
        entries = UserPreferences.shared.tagShortcuts
            .map { TagShortcutEntry(key: $0.key, tag: $0.value) }
            .sorted { $0.key < $1.key }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func save() {
        var dict: [String: String] = [:]
        for entry in entries {
            let key = TagParser.sanitizedTagName(entry.key).lowercased()
            let tag = TagParser.sanitizedTagName(entry.tag)
            guard !key.isEmpty, !tag.isEmpty else { continue }
            dict[key] = tag
        }
        UserPreferences.shared.tagShortcuts = dict
        // Only the shortcut map changed — rebuild just the tag parser's map.
        TagParser.updateShortcuts()
    }
}

// MARK: - Calendar Shortcuts

/// Lets the user define `@` shortcuts (e.g. "@w" → Work) that, when typed while
/// adding a calendar event, are stripped from the text and route the event to
/// the chosen calendar. The event-mode analog of List Shortcuts.
struct CalendarShortcutsSection: View {
    @State private var entries: [ShortcutEntry] = []
    @State private var calendars: [EKCalendar] = []
    @State private var saveWork: DispatchWorkItem?

    struct ShortcutEntry: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var calendarId: String
    }

    var body: some View {
        SettingsSection(String("Calendar Shortcuts")) {
            Text(String("Type a shortcut like “@w” while adding a calendar event (Calendar mode). "
                + "It’s removed from the text and the event is added to the chosen calendar."))
                .modifier(SettingsNoteStyle())

            if !RemindersService.shared.isCalendarAuthorized {
                Button(String("Allow Calendar Access…")) {
                    requestAccess()
                }
                .buttonStyle(.borderless)
            } else if calendars.isEmpty {
                Text(String("No calendars available."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach($entries) { $entry in
                    shortcutRow($entry)
                }

                Button {
                    entries.append(ShortcutEntry(key: "", calendarId: calendars.first?.calendarIdentifier ?? ""))
                } label: {
                    Label(String("Add Shortcut"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .onAppear {
            if RemindersService.shared.isCalendarAuthorized {
                calendars = RemindersService.shared.getAllEventCalendars()
            }
            load()
        }
        .onChange(of: entries) { _ in scheduleSave() }
    }

    private func shortcutRow(_ entry: Binding<ShortcutEntry>) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                Text(String("@")).foregroundStyle(.secondary)
                TextField(String("key"), text: entry.key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(String(""), selection: entry.calendarId) {
                ForEach(calendars, id: \.calendarIdentifier) { calendar in
                    Text(calendar.title).tag(calendar.calendarIdentifier)
                }
            }
            .labelsHidden()

            Spacer()

            Button {
                entries.removeAll { $0.id == entry.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String("Remove shortcut"))
        }
    }

    private func requestAccess() {
        RemindersService.shared.requestCalendarAccess { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    calendars = RemindersService.shared.getAllEventCalendars()
                    load()
                }
            }
        }
    }

    private func load() {
        entries = UserPreferences.shared.eventCalendarShortcuts
            .map { ShortcutEntry(key: $0.key, calendarId: $0.value) }
            .sorted { $0.key < $1.key }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func save() {
        var dict: [String: String] = [:]
        for entry in entries {
            let key = entry.key
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "@", with: "")
                .lowercased()
            guard !key.isEmpty, !entry.calendarId.isEmpty else { continue }
            dict[key] = entry.calendarId
        }
        UserPreferences.shared.eventCalendarShortcuts = dict
        EventCalendarParser.updateShared(with: RemindersService.shared.getAllEventCalendars())
    }
}
