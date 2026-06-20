import SwiftUI
import EventKit

enum SettingsTab: Hashable {
    case general
    case menuBar
    case reminders
    case copy
    case keyboard
    case shortcuts
    case about
}

struct SettingsView: View {
    @ObservedObject private var coordinator = SettingsCoordinator.shared

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

            CopySettingsTab()
                .tabItem {
                    Label(rmbLocalized(.copySettingsTab), rmbSymbol: .docOnDoc)
                }
                .tag(SettingsTab.copy)

            KeyboardSettingsTab()
                .tabItem {
                    Label(rmbLocalized(.keyboardSettingsTab), rmbSymbol: .keyboard)
                }
                .tag(SettingsTab.keyboard)

            ListShortcutsSettingsTab()
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
    }
}

#Preview {
    SettingsView()
}

// MARK: - List Shortcuts

/// Lets the user define `@` shortcuts (e.g. "@p" → Personal) that, when typed
/// in the reminder field, are stripped from the text and assign that list.
struct ListShortcutsSettingsTab: View {
    @State private var entries: [ShortcutEntry] = []
    @State private var calendars: [EKCalendar] = []
    @State private var saveWork: DispatchWorkItem?

    struct ShortcutEntry: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var calendarId: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String("List Shortcuts"))
                .font(.headline)

            Text(String("Type a shortcut like “@p” in the reminder field. It’s removed from the "
                + "text and the reminder is assigned to the chosen list."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if calendars.isEmpty {
                Spacer()
                Text(String("No reminder lists available."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($entries) { $entry in
                            shortcutRow($entry)
                        }
                    }
                }

                Button {
                    entries.append(ShortcutEntry(key: "", calendarId: calendars.first?.calendarIdentifier ?? ""))
                } label: {
                    Label(String("Add Shortcut"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
