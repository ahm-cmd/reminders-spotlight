import Cocoa
import EventKit

@MainActor
final class RightClickMenuHelper: NSObject {
    static let shared = RightClickMenuHelper()

    private override init() {
        super.init()
    }

    // MARK: - Build Menu

    /// The dropdown shown when the menu bar item is clicked.
    func buildStatusBarMenu() -> NSMenu {
        let menu = NSMenu()

        // Quick-entry (mirrors the global ⌥Space shortcut).
        let newReminderItem = makeMenuItem(
            title: String("New Reminder"),
            action: #selector(newReminder),
            systemSymbolName: "plus.circle"
        )
        newReminderItem.keyEquivalent = " "
        newReminderItem.keyEquivalentModifierMask = .option
        menu.addItem(newReminderItem)

        menu.addItem(.separator())

        // Which lists to display.
        addCalendarFilterItems(to: menu)

        menu.addItem(makeMenuItem(
            title: rmbLocalized(.reloadRemindersDataButton),
            action: #selector(reloadData),
            systemSymbolName: "arrow.clockwise"
        ))

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: rmbLocalized(.appSettingsButton),
            action: #selector(openSettingsAction),
            systemSymbolName: "gearshape"
        ))

        menu.addItem(makeMenuItem(
            title: rmbLocalized(.appAboutButton),
            action: #selector(openAbout),
            systemSymbolName: "info.circle"
        ))

        menu.addItem(makeMenuItem(
            title: rmbLocalized(.launchAtLoginOption),
            action: #selector(toggleLaunchAtLogin),
            state: UserPreferences.shared.launchAtLoginIsEnabled ? .on : .off
        ))

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: rmbLocalized(.appQuitButton),
            action: #selector(quitApp),
            systemSymbolName: "xmark.rectangle"
        ))

        return menu
    }

    /// Adds a checkable item per Reminders list; toggling shows/hides that list.
    private func addCalendarFilterItems(to menu: NSMenu) {
        let data = AppDelegate.shared.remindersData
        let calendars = data.availableCalendars
        guard !calendars.isEmpty else { return }

        let header = NSMenuItem(title: String("Show Lists"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let selected = Set(data.calendarIdentifiersFilter)
        for calendar in calendars {
            let item = makeMenuItem(
                title: calendar.title,
                action: #selector(toggleCalendarFilter(_:)),
                state: selected.contains(calendar.calendarIdentifier) ? .on : .off
            )
            item.representedObject = calendar.calendarIdentifier
            item.image = colorDot(calendar.cgColor)
            menu.addItem(item)
        }

        menu.addItem(.separator())
    }

    // MARK: - Helpers

    private func makeMenuItem(
        title: String,
        action: Selector,
        systemSymbolName: String? = nil,
        state: NSControl.StateValue? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let systemSymbolName {
            item.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
        }
        if let state {
            item.state = state
        }
        return item
    }

    /// A small filled circle in the list's color, for the list toggle items.
    private func colorDot(_ cgColor: CGColor?) -> NSImage? {
        guard let cgColor, let color = NSColor(cgColor: cgColor) else { return nil }
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    // MARK: - Actions

    @objc private func newReminder() {
        AppDelegate.shared.openEntryWindow()
    }

    @objc private func toggleCalendarFilter(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        let data = AppDelegate.shared.remindersData
        if data.calendarIdentifiersFilter.contains(identifier) {
            data.calendarIdentifiersFilter.removeAll { $0 == identifier }
        } else {
            data.calendarIdentifiersFilter.append(identifier)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        UserPreferences.shared.launchAtLoginIsEnabled.toggle()
    }

    @objc private func reloadData() {
        NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
    }

    @objc private func openSettingsAction() {
        NSApp.openAppSettings()
    }

    @objc private func openAbout() {
        NSApp.openAppSettings(tab: .about)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
