import EventKit

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let reminder: EKReminder
    let lastModifiedDate: Date?
    let childReminders: [ReminderItem]
    let isChild: Bool
    let hasChildren: Bool
    /// Tag names, resolved once here. Reading tags needs private-selector
    /// reflection, which is far too expensive to repeat on every row render.
    let tagNames: [String]

    init(for reminder: EKReminder, isChild: Bool = false, withChildren childReminders: [ReminderItem] = []) {
        self.id = reminder.calendarItemIdentifier
        self.reminder = reminder
        self.lastModifiedDate = reminder.lastModifiedDate
        self.childReminders = childReminders.sortedReminders
        self.isChild = isChild
        self.hasChildren = !childReminders.isEmpty
        if #available(macOS 12, *) {
            self.tagNames = reminder.ekTags.map(\.name)
        } else {
            self.tagNames = []
        }
    }
    
    static func == (lhs: ReminderItem, rhs: ReminderItem) -> Bool {
        return (
            lhs.id == rhs.id
            && lhs.lastModifiedDate == rhs.lastModifiedDate
            && lhs.childReminders == rhs.childReminders
        )
    }
}
